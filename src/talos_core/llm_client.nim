## Talos LLM client (OpenAI-compatible Chat Completions).
##
## Synchronous HTTP client supporting OpenAI Chat Completions over any
## OpenAI-compatible endpoint (OpenAI, OpenRouter, vLLM, etc.).
##
## Features:
##   - chatCompletion(prompt, history): sends a chat completion request
##   - Parses content and tool_calls from response
##   - Specific error types: AuthError (401), RateLimitError (429),
##     ServerError (5xx), NetworkError, ProtocolError
##   - Simple retry logic (3 attempts with exponential backoff) for
##     rate limits and 5xx server errors
##
## Out of scope (deferred):
##   - Anthropic / Google / non-OpenAI protocols
##   - Async I/O

import std/[httpclient, json, strutils, tables, os]
import util

type
  ChatRole* = enum
    ## Role of a chat message participant.
    crSystem = "system"
    crUser = "user"
    crAssistant = "assistant"
    crTool = "tool"

  ToolCall* = object
    ## A single tool call requested by the assistant.
    id*: string
    name*: string
    arguments*: string               ## JSON-encoded arguments string.

  ChatMessage* = object
    ## A single message in a chat history.
    role*: ChatRole
    content*: string
    name*: string                    ## Optional name for tool messages.
    toolCallId*: string              ## Optional id linking a tool result.
    toolCalls*: seq[ToolCall]        ## Tool calls attached to assistant msg.

  TokenUsage* = object
    ## Token usage statistics from the response.
    promptTokens*: int
    completionTokens*: int
    totalTokens*: int

  ChatResponse* = object
    ## A parsed chat completion response.
    content*: string                 ## "" when assistant returns tool_calls.
    toolCalls*: seq[ToolCall]
    finishReason*: string
    usage*: TokenUsage
    model*: string
    raw*: JsonNode                   ## Raw JSON response for debugging.

  LLMClient* = object
    ## OpenAI-compatible chat completion client.
    baseUrl*: string                 ## e.g. "https://openrouter.ai/api/v1"
    apiKey*: string
    model*: string
    defaultParams*: Table[string, JsonNode]
    timeoutMs*: int                  ## Request timeout in milliseconds.
    maxRetries*: int                 ## Total attempts including the first.
    retryBackoffMs*: int             ## Base backoff in ms (exponential).

  StreamEventKind* = enum
    ## Kinds of streaming events delivered during a chatCompletionStream call.
    sekContent = "content"
    sekToolCallDelta = "tool_call_delta"
    sekFinish = "finish"
    sekError = "error"

  ChatCompletionStreamEvent* = object
    ## A single streaming event.
    kind*: StreamEventKind
    delta*: string                   ## Text delta (sekContent) or tool arg delta.
    toolCallId*: string              ## Tool call id (sekToolCallDelta first chunk).
    toolName*: string                ## Tool name (sekToolCallDelta first chunk).
    finishReason*: string            ## On sekFinish.
    usage*: TokenUsage               ## On sekFinish (if present).

  OnStreamEvent* = proc(event: ChatCompletionStreamEvent) {.gcsafe, raises: [].}
    ## Callback invoked for each streaming delta. Called synchronously
    ## inside chatCompletionStream; must not block for long.
  LLMError* = object of CatchableError
    ## Base type for all LLM client errors.
    statusCode*: int

  AuthError* = object of LLMError       ## 401 Unauthorized
  RateLimitError* = object of LLMError  ## 429 Too Many Requests
  ServerError* = object of LLMError     ## 5xx
  ClientError* = object of LLMError     ## Other 4xx
  NetworkError* = object of LLMError    ## Connection / IO failure
  ProtocolError* = object of LLMError   ## Invalid / unparseable response

const
  DefaultTimeoutMs* = 60_000
  DefaultMaxRetries* = 3
  DefaultRetryBackoffMs* = 500

proc newLLMClient*(
    baseUrl: string;
    apiKey: string;
    model: string;
    defaultParams: Table[string, JsonNode] = initTable[string, JsonNode]();
    timeoutMs: int = DefaultTimeoutMs;
    maxRetries: int = DefaultMaxRetries;
    retryBackoffMs: int = DefaultRetryBackoffMs;
): LLMClient =
  ## Constructs a new LLMClient. baseUrl should NOT include "/chat/completions".
  result = LLMClient(
    baseUrl: baseUrl.strip(chars = {'/'}, leading = false),
    apiKey: apiKey,
    model: model,
    defaultParams: defaultParams,
    timeoutMs: timeoutMs,
    maxRetries: max(1, maxRetries),
    retryBackoffMs: max(0, retryBackoffMs),
  )


proc messageToJson(msg: ChatMessage): JsonNode =
  result = newJObject()
  result["role"] = %($msg.role)
  # When the assistant calls tools, content may be empty/null.
  if msg.role == crAssistant and msg.toolCalls.len > 0 and msg.content.len == 0:
    result["content"] = newJNull()
  else:
    result["content"] = %msg.content
  if msg.name.len > 0:
    result["name"] = %msg.name
  if msg.toolCallId.len > 0:
    result["tool_call_id"] = %msg.toolCallId
  if msg.toolCalls.len > 0:
    var arr = newJArray()
    for tc in msg.toolCalls:
      var fnObj = newJObject()
      fnObj["name"] = %tc.name
      fnObj["arguments"] = %tc.arguments
      var tcObj = newJObject()
      tcObj["id"] = %tc.id
      tcObj["type"] = %"function"
      tcObj["function"] = fnObj
      arr.add(tcObj)
    result["tool_calls"] = arr

proc buildRequestBody*(
    client: LLMClient;
    messages: seq[ChatMessage];
    extraParams: Table[string, JsonNode];
): JsonNode =
  result = newJObject()
  result["model"] = %client.model
  var msgArr = newJArray()
  for m in messages:
    msgArr.add(messageToJson(m))
  result["messages"] = msgArr
  for k, v in client.defaultParams:
    result[k] = v
  for k, v in extraParams:
    result[k] = v

proc parseToolCalls(node: JsonNode): seq[ToolCall] =
  result = @[]
  if node.isNil or node.kind != JArray:
    return
  for tcNode in node:
    if tcNode.kind != JObject:
      continue
    var tc = ToolCall()
    if tcNode.hasKey("id") and tcNode["id"].kind == JString:
      tc.id = tcNode["id"].getStr()
    if tcNode.hasKey("function") and tcNode["function"].kind == JObject:
      let fn = tcNode["function"]
      if fn.hasKey("name") and fn["name"].kind == JString:
        tc.name = fn["name"].getStr()
      if fn.hasKey("arguments"):
        # arguments is typically a JSON-encoded string, but be lenient.
        if fn["arguments"].kind == JString:
          tc.arguments = fn["arguments"].getStr()
        else:
          tc.arguments = $fn["arguments"]
    result.add(tc)

proc parseResponse(body: string): ChatResponse =
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError as e:
    raise newException(ProtocolError,
      "Invalid JSON response: " & e.msg)

  if node.kind != JObject:
    raise newException(ProtocolError, "Response root must be an object")

  if not node.hasKey("choices") or node["choices"].kind != JArray or
     node["choices"].len == 0:
    raise newException(ProtocolError, "Response missing 'choices' array")

  let choice = node["choices"][0]
  if choice.kind != JObject or not choice.hasKey("message"):
    raise newException(ProtocolError, "Choice missing 'message' field")

  let message = choice["message"]
  # e.g. {"message": null, ...}: .hasKey on a non-object raises an
  # uncatchable AssertionDefect, which no caller's `except LLMError` sees.
  if message.kind != JObject:
    raise newException(ProtocolError, "'message' field is not an object")
  result = ChatResponse(raw: node)

  if message.hasKey("content") and message["content"].kind == JString:
    result.content = message["content"].getStr()
  # content may be JNull when tool_calls are present; leave as ""

  if message.hasKey("tool_calls"):
    result.toolCalls = parseToolCalls(message["tool_calls"])

  if choice.hasKey("finish_reason") and choice["finish_reason"].kind == JString:
    result.finishReason = choice["finish_reason"].getStr()

  if node.hasKey("model") and node["model"].kind == JString:
    result.model = node["model"].getStr()

  if node.hasKey("usage") and node["usage"].kind == JObject:
    let u = node["usage"]
    if u.hasKey("prompt_tokens") and u["prompt_tokens"].kind == JInt:
      result.usage.promptTokens = u["prompt_tokens"].getInt()
    if u.hasKey("completion_tokens") and u["completion_tokens"].kind == JInt:
      result.usage.completionTokens = u["completion_tokens"].getInt()
    if u.hasKey("total_tokens") and u["total_tokens"].kind == JInt:
      result.usage.totalTokens = u["total_tokens"].getInt()

proc extractApiErrorMessage(body: string): string =
  ## Extracts a human-readable error message from a (possibly OpenAI-style)
  ## error response body. Returns the raw body if parsing fails.
  try:
    let node = parseJson(body)
    if node.kind == JObject and node.hasKey("error"):
      let err = node["error"]
      if err.kind == JObject and err.hasKey("message") and
         err["message"].kind == JString:
        return err["message"].getStr()
      if err.kind == JString:
        return err.getStr()
  except CatchableError as e:
    stderr.writeLine("talos: extractApiErrorMessage failed: " & e.msg)
  return body

proc raiseForStatus*(status: int; body: string) =
  ## Raises the appropriate LLMError subtype for a non-2xx HTTP status.
  let msg = extractApiErrorMessage(body)
  case status
  of 401, 403:
    var e = newException(AuthError,
      "Authentication failed (HTTP " & $status & "): " & msg)
    e.statusCode = status
    raise e
  of 429:
    var e = newException(RateLimitError,
      "Rate limit exceeded (HTTP 429): " & msg)
    e.statusCode = status
    raise e
  else:
    if status >= 500 and status < 600:
      var e = newException(ServerError,
        "Server error (HTTP " & $status & "): " & msg)
      e.statusCode = status
      raise e
    elif status >= 400 and status < 500:
      var e = newException(ClientError,
        "Client error (HTTP " & $status & "): " & msg)
      e.statusCode = status
      raise e
    else:
      var e = newException(ProtocolError,
        "Unexpected HTTP status " & $status & ": " & msg)
      e.statusCode = status
      raise e


proc doRequest(
    client: LLMClient;
    url, body: string;
): tuple[status: int, body: string] =
  ## Issues a single HTTP POST. Raises NetworkError on connection failure.
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
    let resp = http.request(url, httpMethod = HttpPost, body = body)
    let status = parseStatusCode(resp.status)
    let respBody = resp.body
    return (status, respBody)
  except HttpRequestError as e:
    raise newException(NetworkError, "HTTP request failed: " & e.msg)
  except OSError as e:
    raise newException(NetworkError, "Network/OS error: " & e.msg)
  except IOError as e:
    raise newException(NetworkError, "I/O error: " & e.msg)

proc chatCompletion*(
    client: LLMClient;
    prompt: string;
    history: seq[ChatMessage] = @[];
    extraParams: Table[string, JsonNode] = initTable[string, JsonNode]();
): ChatResponse =
  ## Sends a chat completion request. The `prompt` is appended as a final
  ## user message after `history`. To send a fully custom message list,
  ## pass an empty prompt and provide messages via history.
  ##
  ## Retries on 429 and 5xx with exponential backoff up to client.maxRetries
  ## attempts. Other errors are raised immediately.
  var messages = history
  if prompt.len > 0:
    messages.add(ChatMessage(role: crUser, content: prompt))

  let body = $buildRequestBody(client, messages, extraParams)
  let url = client.baseUrl & "/chat/completions"

  var attempt = 0
  var lastErr: ref LLMError = nil
  while attempt < client.maxRetries:
    inc attempt
    var status = 0
    var respBody = ""
    try:
      let r = doRequest(client, url, body)
      status = r.status
      respBody = r.body
    except NetworkError as e:
      lastErr = e
      if attempt < client.maxRetries:
        sleep(client.retryBackoffMs * (1 shl min(attempt - 1, 30)))
        continue
      raise e

    if status >= 200 and status < 300:
      return parseResponse(respBody)

    # Retry on 429 and 5xx
    if (status == 429 or (status >= 500 and status < 600)) and
       attempt < client.maxRetries:
      sleep(client.retryBackoffMs * (1 shl min(attempt - 1, 30)))
      continue

    raiseForStatus(status, respBody)

  # Exhausted retries with only NetworkError encountered
  if lastErr != nil:
    raise lastErr
  raise newException(LLMError, "chatCompletion failed without a recorded error")

