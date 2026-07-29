## LLM client builder from a TalosConfig.
##
## Centralizes the `TalosConfig → LLMClient` construction so callers
## don't need to know the details of endpoint URL, API key, and model
## selection. Used by both `talos_agent` and `talos_code`.

import std/[strutils]

import talos_core/config
import talos_core/embeddings
import talos_core/llm_client

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

proc buildLLMClient*(cfg: TalosConfig): LLMClient =
  ## Builds an LLMClient from a fully-resolved TalosConfig.
  newLLMClient(
    baseUrl = activeBaseUrl(cfg),
    apiKey  = activeApiKey(cfg),
    model   = activeModel(cfg),
  )

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