## Talos embeddings client (OpenAI-compatible /v1/embeddings).
##
## Synchronous HTTP client for text embeddings over any OpenAI-compatible
## endpoint (OpenRouter, OpenAI, vLLM, etc.) — same auth/transport shape as
## llm_client.nim's chat completions client, reused error types included.
##
## Out of scope (deferred):
##   - Batched multi-input requests (one string in, one vector out for now)
##   - Async I/O

import std/[httpclient, json, os, math, strutils]
import talos_core/llm_client  # reuse LLMError hierarchy + raiseForStatus
import util

type
  EmbeddingClient* = object
    baseUrl*: string          ## e.g. "https://openrouter.ai/api/v1"
    apiKey*: string
    model*: string             ## e.g. "openai/text-embedding-3-large"
    timeoutMs*: int
    maxRetries*: int
    retryBackoffMs*: int

  EmbeddingResult* = object
    vector*: seq[float32]
    tokensUsed*: int

const
  DefaultEmbeddingTimeoutMs* = 30_000
  DefaultEmbeddingMaxRetries* = 3
  DefaultEmbeddingRetryBackoffMs* = 500
  ## Winner of the empirical eval in scripts/eval_embeddings.nim (2026-07-28):
  ## same-topic vs. cross-topic similarity margins were text-embedding-3-large
  ## 0.5423, text-embedding-3-small 0.5499 (statistically indistinguishable —
  ## small sample), gemini-embedding-001 0.3134, bge-m3 0.3527. Both OpenAI
  ## models clearly beat the alternatives; -large is the pick for its higher
  ## dimensionality (headroom as the retained-fact corpus grows) since cost
  ## is immaterial at personal-single-user scale.
  DefaultEmbeddingModel* = "openai/text-embedding-3-large"

proc newEmbeddingClient*(
    baseUrl: string;
    apiKey: string;
    model: string = DefaultEmbeddingModel;
    timeoutMs: int = DefaultEmbeddingTimeoutMs;
    maxRetries: int = DefaultEmbeddingMaxRetries;
    retryBackoffMs: int = DefaultEmbeddingRetryBackoffMs;
): EmbeddingClient =
  result = EmbeddingClient(
    baseUrl: baseUrl.strip(chars = {'/'}, leading = false),
    apiKey: apiKey,
    model: model,
    timeoutMs: timeoutMs,
    maxRetries: max(1, maxRetries),
    retryBackoffMs: max(0, retryBackoffMs),
  )

proc buildEmbeddingRequestBody(client: EmbeddingClient; text: string): JsonNode =
  result = newJObject()
  result["model"] = %client.model
  result["input"] = %text
  result["encoding_format"] = %"float"

proc parseEmbeddingResponse(body: string): EmbeddingResult =
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError as e:
    raise newException(llm_client.ProtocolError, "Invalid JSON response: " & e.msg)

  if node.kind != JObject:
    raise newException(llm_client.ProtocolError, "Response root must be an object")

  if not node.hasKey("data") or node["data"].kind != JArray or node["data"].len == 0:
    raise newException(llm_client.ProtocolError, "Response missing 'data' array")

  let first = node["data"][0]
  if first.kind != JObject or not first.hasKey("embedding") or
     first["embedding"].kind != JArray:
    raise newException(llm_client.ProtocolError, "'data[0]' missing 'embedding' array")

  var vec: seq[float32] = @[]
  for x in first["embedding"]:
    case x.kind
    of JFloat: vec.add(x.getFloat().float32)
    of JInt:   vec.add(x.getInt().float32)
    else:
      raise newException(llm_client.ProtocolError, "embedding element is not numeric")
  result.vector = vec

  if node.hasKey("usage") and node["usage"].kind == JObject:
    let u = node["usage"]
    if u.hasKey("total_tokens") and u["total_tokens"].kind == JInt:
      result.tokensUsed = u["total_tokens"].getInt()

proc doEmbeddingRequest(
    client: EmbeddingClient;
    body: string;
): tuple[status: int, body: string] =
  let http = newHttpClient(timeout = client.timeoutMs)
  defer: http.close()
  http.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Accept": "application/json",
    "User-Agent": "talos-agent/0.1",
  })
  if client.apiKey.len > 0:
    http.headers["Authorization"] = "Bearer " & client.apiKey
  try:
    let resp = http.request(client.baseUrl & "/embeddings", httpMethod = HttpPost, body = body)
    return (parseStatusCode(resp.status), resp.body)
  except HttpRequestError as e:
    raise newException(llm_client.NetworkError, "HTTP request failed: " & e.msg)
  except OSError as e:
    raise newException(llm_client.NetworkError, "Network/OS error: " & e.msg)
  except IOError as e:
    raise newException(llm_client.NetworkError, "I/O error: " & e.msg)

proc getEmbedding*(client: EmbeddingClient; text: string): EmbeddingResult =
  ## Fetches an embedding vector for `text`. Retries on 429/5xx with
  ## exponential backoff up to client.maxRetries attempts, matching
  ## llm_client.chatCompletion's retry behavior.
  let body = $buildEmbeddingRequestBody(client, text)

  var attempt = 0
  var lastErr: ref llm_client.LLMError = nil
  while attempt < client.maxRetries:
    inc attempt
    var status = 0
    var respBody = ""
    try:
      let r = doEmbeddingRequest(client, body)
      status = r.status
      respBody = r.body
    except llm_client.NetworkError as e:
      lastErr = e
      if attempt < client.maxRetries:
        sleep(client.retryBackoffMs * (1 shl min(attempt - 1, 30)))
        continue
      raise e

    if status >= 200 and status < 300:
      return parseEmbeddingResponse(respBody)

    if (status == 429 or (status >= 500 and status < 600)) and
       attempt < client.maxRetries:
      sleep(client.retryBackoffMs * (1 shl min(attempt - 1, 30)))
      continue

    raiseForStatus(status, respBody)

  if lastErr != nil:
    raise lastErr
  raise newException(llm_client.LLMError, "getEmbedding failed without a recorded error")

proc cosineSimilarity*(a, b: seq[float32]): float32 =
  ## Standard cosine similarity. Returns 0.0 if either vector has zero norm
  ## or the vectors differ in length (mismatched embedding models).
  if a.len != b.len or a.len == 0:
    return 0.0'f32
  var dot, normA, normB: float64 = 0.0
  for i in 0 ..< a.len:
    dot += a[i].float64 * b[i].float64
    normA += a[i].float64 * a[i].float64
    normB += b[i].float64 * b[i].float64
  if normA == 0.0 or normB == 0.0:
    return 0.0'f32
  result = (dot / (sqrt(normA) * sqrt(normB))).float32
