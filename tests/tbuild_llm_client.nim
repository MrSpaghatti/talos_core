## Tests for talos_core/build_llm_client.nim — role-based model routing
## (task-13).

import std/[tables, unittest]
import talos_core/config
import talos_core/build_llm_client
import talos_core/llm_client
import talos_core/testkit/mock_llm_server

const SuccessBody = """
{
  "id": "chatcmpl-1",
  "object": "chat.completion",
  "model": "test-model",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "Hello!"},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10}
}
"""

const RateLimitBody = """{"error": {"message": "Too many requests"}}"""
const ServerErrBody = """{"error": {"message": "upstream timeout"}}"""
const AuthErrBody = """{"error": {"message": "Invalid API key"}}"""

var sharedServer = startMockServer()

proc baseConfig(): TalosConfig =
  result = defaultConfig()
  result.provider = "openrouter"
  result.openrouterEndpoint = baseUrlFor(sharedServer)
  result.openrouterModel = "legacy-default-model"
  result.openrouterApiKey = "test-key"

# ---------------------------------------------------------------------------
# Suite: resolveRole
# ---------------------------------------------------------------------------

suite "resolveRole":
  test "an unconfigured role falls back entirely to the legacy fields":
    let cfg = baseConfig()
    let rc = resolveRole(cfg, "default")
    check rc.provider == "openrouter"
    check rc.model == "legacy-default-model"
    check rc.fallback.len == 0

  test "an unconfigured non-default role also falls back to legacy fields":
    let cfg = baseConfig()
    let rc = resolveRole(cfg, "plan")
    check rc.provider == "openrouter"
    check rc.model == "legacy-default-model"

  test "a configured role wins outright":
    var cfg = baseConfig()
    cfg.roles["plan"] = ModelRoleConfig(
      provider: "openrouter", model: "anthropic/claude-opus-4", fallback: @[])
    let rc = resolveRole(cfg, "plan")
    check rc.model == "anthropic/claude-opus-4"

  test "a configured role with a blank model inherits the legacy model":
    var cfg = baseConfig()
    cfg.roles["smol"] = ModelRoleConfig(provider: "openrouter", model: "", fallback: @[])
    let rc = resolveRole(cfg, "smol")
    check rc.model == "legacy-default-model"

  test "a configured role with a blank provider inherits cfg.provider":
    var cfg = baseConfig()
    cfg.roles["smol"] = ModelRoleConfig(provider: "", model: "cheap-model", fallback: @[])
    let rc = resolveRole(cfg, "smol")
    check rc.provider == "openrouter"

  test "fallback list is passed through unchanged":
    var cfg = baseConfig()
    cfg.roles["smol"] = ModelRoleConfig(
      provider: "openrouter", model: "cheap", fallback: @["cheap-2", "cheap-3"])
    let rc = resolveRole(cfg, "smol")
    check rc.fallback == @["cheap-2", "cheap-3"]

# ---------------------------------------------------------------------------
# Suite: buildLLMClient / buildLLMClientChain
# ---------------------------------------------------------------------------

suite "buildLLMClient with roles":
  test "buildLLMClient(cfg) and buildLLMClient(cfg, \"default\") agree on a config with no roles":
    let cfg = baseConfig()
    let a = buildLLMClient(cfg)
    let b = buildLLMClient(cfg, "default")
    check a.model == b.model
    check a.baseUrl == b.baseUrl

  test "buildLLMClient routes through a configured role's model":
    var cfg = baseConfig()
    cfg.roles["plan"] = ModelRoleConfig(
      provider: "openrouter", model: "anthropic/claude-opus-4", fallback: @[])
    let client = buildLLMClient(cfg, "plan")
    check client.model == "anthropic/claude-opus-4"

  test "buildLLMClientChain has exactly one element when no fallback configured":
    let cfg = baseConfig()
    let chain = buildLLMClientChain(cfg, "default")
    check chain.len == 1
    check chain[0].model == "legacy-default-model"

  test "buildLLMClientChain includes primary followed by each fallback model":
    var cfg = baseConfig()
    cfg.roles["smol"] = ModelRoleConfig(
      provider: "openrouter", model: "primary-model", fallback: @["fb-1", "fb-2"])
    let chain = buildLLMClientChain(cfg, "smol")
    check chain.len == 3
    check chain[0].model == "primary-model"
    check chain[1].model == "fb-1"
    check chain[2].model == "fb-2"

# ---------------------------------------------------------------------------
# Suite: chatCompletionWithRole — fallback chain behavior
# ---------------------------------------------------------------------------

suite "chatCompletionWithRole":
  setup:
    resetMock(sharedServer)

  test "a role with no fallback behaves like a plain chatCompletion on success":
    let cfg = baseConfig()
    sharedServer.enqueue("200 OK", SuccessBody)
    let resp = chatCompletionWithRole(cfg, "default", prompt = "hi")
    check resp.content == "Hello!"

  test "a non-fallback-worthy error (auth) propagates immediately without trying a fallback":
    var cfg = baseConfig()
    cfg.roles["smol"] = ModelRoleConfig(
      provider: "openrouter", model: "primary-model", fallback: @["fb-1"])
    sharedServer.enqueue("401 Unauthorized", AuthErrBody)
    expect AuthError:
      discard chatCompletionWithRole(cfg, "smol", prompt = "hi")
    # Only the primary model's single request should have been made — the
    # fallback model was never tried.
    check sharedServer.requestCount == 1

  test "rate-limit errors that exhaust the primary model's own retries fall through to the next model":
    var cfg = baseConfig()
    cfg.roles["smol"] = ModelRoleConfig(
      provider: "openrouter", model: "primary-model", fallback: @["fallback-model"])
    # Primary client's own internal retry/backoff (default maxRetries=3)
    # exhausts on three consecutive 429s; the fallback client then succeeds
    # on its first attempt.
    sharedServer.enqueue("429 Too Many Requests", RateLimitBody)
    sharedServer.enqueue("429 Too Many Requests", RateLimitBody)
    sharedServer.enqueue("429 Too Many Requests", RateLimitBody)
    sharedServer.enqueue("200 OK", SuccessBody)
    let resp = chatCompletionWithRole(cfg, "smol", prompt = "hi")
    check resp.content == "Hello!"
    check sharedServer.requestCount == 4

  test "server errors that exhaust the primary model's own retries fall through to the next model":
    var cfg = baseConfig()
    cfg.roles["smol"] = ModelRoleConfig(
      provider: "openrouter", model: "primary-model", fallback: @["fallback-model"])
    sharedServer.enqueue("503 Service Unavailable", ServerErrBody)
    sharedServer.enqueue("503 Service Unavailable", ServerErrBody)
    sharedServer.enqueue("503 Service Unavailable", ServerErrBody)
    sharedServer.enqueue("200 OK", SuccessBody)
    let resp = chatCompletionWithRole(cfg, "smol", prompt = "hi")
    check resp.content == "Hello!"

  test "an error that survives every model in the chain propagates as the last model's error":
    var cfg = baseConfig()
    cfg.roles["smol"] = ModelRoleConfig(
      provider: "openrouter", model: "primary-model", fallback: @["fallback-model"])
    for i in 0 ..< 6:
      sharedServer.enqueue("429 Too Many Requests", RateLimitBody)
    expect RateLimitError:
      discard chatCompletionWithRole(cfg, "smol", prompt = "hi")
