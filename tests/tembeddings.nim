## Tests for talos_core/embeddings.nim
##
## Reuses the socket-based mock server from testkit/mock_llm_server.nim
## (path-agnostic — just replies with queued responses in FIFO order),
## same pattern as tllm_client.nim.

import std/[unittest, math, strutils]
import talos_core/embeddings
import talos_core/llm_client
import talos_core/testkit/mock_llm_server

const SuccessBody = """
{
  "data": [{"embedding": [0.1, 0.2, 0.3], "index": 0}],
  "usage": {"total_tokens": 5}
}
"""

const AuthErrBody = """{"error": {"message": "Invalid API key"}}"""
const RateLimitBody = """{"error": {"message": "Too many requests"}}"""

var sharedServer = startMockServer()

proc makeEmbedClient(maxRetries = 3; backoffMs = 5): EmbeddingClient =
  newEmbeddingClient(
    baseUrl = baseUrlFor(sharedServer),
    apiKey = "test-key",
    model = "test-embed-model",
    maxRetries = maxRetries,
    retryBackoffMs = backoffMs,
    timeoutMs = 5_000,
  )

suite "embeddings: getEmbedding success":
  setup:
    resetMock(sharedServer)

  test "parses vector and token usage from a successful response":
    sharedServer.enqueue("200 OK", SuccessBody)
    let client = makeEmbedClient()
    let r = client.getEmbedding("hello world")
    check r.vector == @[0.1'f32, 0.2'f32, 0.3'f32]
    check r.tokensUsed == 5

  test "sends the model and input in the request body":
    sharedServer.enqueue("200 OK", SuccessBody)
    let client = makeEmbedClient()
    discard client.getEmbedding("hello world")
    let body = sharedServer.requestBodies[^1]
    check "test-embed-model" in body
    check "hello world" in body

suite "embeddings: error handling":
  setup:
    resetMock(sharedServer)

  test "401 raises AuthError":
    sharedServer.enqueue("401 Unauthorized", AuthErrBody)
    let client = makeEmbedClient()
    expect(AuthError):
      discard client.getEmbedding("x")

  test "429 retries then succeeds":
    sharedServer.enqueue("429 Too Many Requests", RateLimitBody)
    sharedServer.enqueue("200 OK", SuccessBody)
    let client = makeEmbedClient()
    let r = client.getEmbedding("x")
    check r.vector.len == 3
    check sharedServer.requestCount == 2

  test "malformed JSON raises ProtocolError":
    sharedServer.enqueue("200 OK", "not json")
    let client = makeEmbedClient()
    expect(ProtocolError):
      discard client.getEmbedding("x")

  test "missing data array raises ProtocolError":
    sharedServer.enqueue("200 OK", """{"usage": {"total_tokens": 1}}""")
    let client = makeEmbedClient()
    expect(ProtocolError):
      discard client.getEmbedding("x")

suite "cosineSimilarity":
  test "identical vectors have similarity 1.0":
    let v = @[1.0'f32, 2.0'f32, 3.0'f32]
    check abs(cosineSimilarity(v, v) - 1.0'f32) < 0.0001'f32

  test "orthogonal vectors have similarity 0.0":
    let a = @[1.0'f32, 0.0'f32]
    let b = @[0.0'f32, 1.0'f32]
    check abs(cosineSimilarity(a, b)) < 0.0001'f32

  test "opposite vectors have similarity -1.0":
    let a = @[1.0'f32, 0.0'f32]
    let b = @[-1.0'f32, 0.0'f32]
    check abs(cosineSimilarity(a, b) - (-1.0'f32)) < 0.0001'f32

  test "mismatched lengths return 0.0":
    check cosineSimilarity(@[1.0'f32], @[1.0'f32, 2.0'f32]) == 0.0'f32

  test "empty vectors return 0.0":
    check cosineSimilarity(@[], @[]) == 0.0'f32

  test "zero vector returns 0.0":
    check cosineSimilarity(@[0.0'f32, 0.0'f32], @[1.0'f32, 1.0'f32]) == 0.0'f32

stopMockServer(sharedServer)
