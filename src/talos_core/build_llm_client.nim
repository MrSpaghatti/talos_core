## LLM client builder from a TalosConfig.
##
## Centralizes the `TalosConfig → LLMClient` construction so callers
## don't need to know the details of endpoint URL, API key, and model
## selection. Used by both `talos_agent` and `talos_code`.
##
## Role-based routing (task-13): `TalosConfig.roles` maps a role name (e.g.
## "plan", "smol") to a `ModelRoleConfig` (provider/model/fallback). A role
## absent from `roles` — including "default" on any config written before
## roles existed — resolves to the legacy single-model provider/*Model
## fields, so existing single-model configs are unaffected.

import std/[strutils, tables, json]

import talos_core/config
import talos_core/embeddings
import talos_core/llm_client

const DefaultRole* = "default"

proc activeBaseUrl*(cfg: TalosConfig): string =
  case cfg.provider.toLowerAscii()
  of "vllm":      cfg.vllmEndpoint
  of "openrouter": cfg.openrouterEndpoint
  else:           DefaultOpenrouterEndpoint

proc activeApiKey*(cfg: TalosConfig): string =
  case cfg.provider.toLowerAscii()
  of "openrouter": cfg.openrouterApiKey
  of "vllm":      ""
  else:           ""

proc activeModel*(cfg: TalosConfig): string =
  case cfg.provider.toLowerAscii()
  of "vllm":      cfg.vllmModel
  of "openrouter": cfg.openrouterModel
  else:           DefaultOpenrouterModel

proc baseUrlForProvider(cfg: TalosConfig; provider: string): string =
  case provider.toLowerAscii()
  of "vllm":       cfg.vllmEndpoint
  of "openrouter": cfg.openrouterEndpoint
  else:            DefaultOpenrouterEndpoint

proc apiKeyForProvider(cfg: TalosConfig; provider: string): string =
  case provider.toLowerAscii()
  of "openrouter": cfg.openrouterApiKey
  else:            ""

proc resolveRole*(cfg: TalosConfig; role: string): ModelRoleConfig =
  ## Resolves `role` to a concrete provider/model/fallback triple. A role
  ## configured in `cfg.roles` wins outright; any field left blank in that
  ## entry (provider, model) inherits from the legacy single-model fields.
  ## A role not present in `cfg.roles` at all — including "default" on a
  ## config with no `[roles.*]` sections — falls back entirely to the
  ## legacy fields, so pre-roles configs behave identically to today.
  if cfg.roles.hasKey(role):
    let r = cfg.roles[role]
    result = ModelRoleConfig(
      provider: if r.provider.len > 0: r.provider else: cfg.provider,
      model: if r.model.len > 0: r.model else: activeModel(cfg),
      fallback: r.fallback,
    )
  else:
    result = ModelRoleConfig(
      provider: cfg.provider,
      model: activeModel(cfg),
      fallback: @[],
    )

proc buildLLMClient*(cfg: TalosConfig; role: string = DefaultRole): LLMClient =
  ## Builds an LLMClient for `role` (default: the implicit "default" role,
  ## i.e. today's single-model behavior).
  let rc = resolveRole(cfg, role)
  newLLMClient(
    baseUrl = baseUrlForProvider(cfg, rc.provider),
    apiKey  = apiKeyForProvider(cfg, rc.provider),
    model   = rc.model,
  )

proc buildLLMClientChain*(cfg: TalosConfig; role: string = DefaultRole): seq[LLMClient] =
  ## Builds the ordered chain of clients for `role`: the role's primary
  ## model followed by each configured fallback model, all sharing the
  ## role's provider/baseUrl/apiKey. Always has at least one element.
  let rc = resolveRole(cfg, role)
  let baseUrl = baseUrlForProvider(cfg, rc.provider)
  let apiKey = apiKeyForProvider(cfg, rc.provider)
  result.add(newLLMClient(baseUrl = baseUrl, apiKey = apiKey, model = rc.model))
  for m in rc.fallback:
    result.add(newLLMClient(baseUrl = baseUrl, apiKey = apiKey, model = m))

proc chatCompletionWithRole*(
    cfg: TalosConfig;
    role: string;
    prompt: string;
    history: seq[ChatMessage] = @[];
    extraParams: Table[string, JsonNode] = initTable[string, JsonNode]();
): ChatResponse =
  ## Like `LLMClient.chatCompletion`, but resolves `role` to a chain of
  ## clients (primary + configured fallbacks) and advances to the next
  ## model in the chain on a `RateLimitError`/`ServerError` that survives
  ## the primary client's own internal retries — i.e. this is a second,
  ## coarser retry layer on top of `llm_client.nim`'s existing per-model
  ## retry/backoff, not a replacement for it. Other error kinds (auth,
  ## network, protocol, client errors) are never fallback-worthy — they
  ## indicate a broken request or credential, not an overloaded model —
  ## so they propagate immediately from whichever client raised them.
  let chain = buildLLMClientChain(cfg, role)
  var lastErr: ref LLMError = nil
  for i, client in chain:
    try:
      return client.chatCompletion(prompt = prompt, history = history, extraParams = extraParams)
    except RateLimitError as e:
      lastErr = e
    except ServerError as e:
      lastErr = e
  raise lastErr

proc buildEmbeddingClient*(cfg: TalosConfig): EmbeddingClient =
  ## Builds an EmbeddingClient from a fully-resolved TalosConfig. Always
  ## routes via cfg.embeddingEndpoint (OpenRouter by default) using the
  ## OpenRouter API key, independent of cfg.provider — see
  ## scripts/eval_embeddings.nim for why embeddings specifically don't
  ## follow the vllm/openrouter provider switch chat completions use.
  newEmbeddingClient(
    baseUrl = cfg.embeddingEndpoint,
    apiKey  = cfg.openrouterApiKey,
    model   = cfg.embeddingModel,
  )