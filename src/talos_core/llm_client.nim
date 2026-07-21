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

import std/[httpclient, json, strutils, tables, os, net, uri, algorithm]

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

proc buildRequestBody(
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

proc raiseForStatus(status: int; body: string) =
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

proc parseStatusCode(status: string): int =
  ## Parses the integer code from an HTTP status line like "200 OK".
  let s = status.strip()
  let spaceIdx = s.find(' ')
  let codePart = if spaceIdx >= 0: s[0 ..< spaceIdx] else: s
  try:
    return parseInt(codePart)
  except ValueError:
    return 0

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
        sleep(client.retryBackoffMs * (1 shl (attempt - 1)))
        continue
      raise e

    if status >= 200 and status < 300:
      return parseResponse(respBody)

    # Retry on 429 and 5xx
    if (status == 429 or (status >= 500 and status < 600)) and
       attempt < client.maxRetries:
      sleep(client.retryBackoffMs * (1 shl (attempt - 1)))
      continue

    raiseForStatus(status, respBody)

  # Exhausted retries with only NetworkError encountered
  if lastErr != nil:
    raise lastErr
  raise newException(LLMError, "chatCompletion failed without a recorded error")

# ---------------------------------------------------------------------------
# Streaming (SSE)
# ---------------------------------------------------------------------------

proc aggregateStreamingToolCalls(deltas: seq[JsonNode]): seq[ToolCall] =
  ## Aggregates streaming tool_call deltas into a final list of ToolCalls.
  ## OpenAI streams tool calls as incremental updates keyed by index.
  result = @[]
  var byIndex = initTable[int, tuple[id, name, args: string]]()
  for node in deltas:
    var idx = 0
    if node.hasKey("index") and node["index"].kind == JInt:
      idx = node["index"].getInt()
    var entry = byIndex.getOrDefault(idx, ("", "", ""))
    if node.hasKey("id") and node["id"].kind == JString:
      entry.id = node["id"].getStr()
    if node.hasKey("function") and node["function"].kind == JObject:
      let fn = node["function"]
      if fn.hasKey("name") and fn["name"].kind == JString:
        entry.name = fn["name"].getStr()
      if fn.hasKey("arguments") and fn["arguments"].kind == JString:
        entry.args.add(fn["arguments"].getStr())
    byIndex[idx] = entry
  # Emit in index order
  var indices: seq[int] = @[]
  for k in byIndex.keys: indices.add(k)
  indices.sort()
  for idx in indices:
    let e = byIndex[idx]
    if e.name.len > 0:
      result.add(ToolCall(id: e.id, name: e.name, arguments: e.args))

type
  BodyReader = object
    ## Line-oriented reader over a response body that transparently
    ## undoes HTTP chunked transfer-encoding when present. Bypasses
    ## `Socket.recvLine`'s blank-line convention (it pads a genuine blank
    ## line to "\r\n" to distinguish it from disconnection) so callers see
    ## plain, unambiguous lines instead.
    sock: Socket
    chunked: bool
    timeoutMs: int
    pending: string
    chunkRemaining: int
    eof: bool

proc fillMore(r: var BodyReader) =
  if r.eof:
    return
  if r.chunked:
    if r.chunkRemaining == 0:
      let sizeLine = r.sock.recvLine(timeout = r.timeoutMs)
      if sizeLine.len == 0:
        r.eof = true
        return
      let hexPart = block:
        let semiIdx = sizeLine.find(';')
        (if semiIdx >= 0: sizeLine[0 ..< semiIdx] else: sizeLine).strip()
      var size = 0
      try:
        size = parseHexInt(hexPart)
      except ValueError:
        r.eof = true
        return
      if size == 0:
        # Terminal chunk: consume optional trailer headers up to the
        # final blank line, then signal end of body.
        while true:
          let trailer = r.sock.recvLine(timeout = r.timeoutMs)
          if trailer.len == 0 or trailer == "\r\n":
            break
        r.eof = true
        return
      r.chunkRemaining = size
    var remaining = r.chunkRemaining
    while remaining > 0:
      let data = r.sock.recv(remaining, timeout = r.timeoutMs)
      if data.len == 0:
        r.eof = true
        return
      r.pending.add(data)
      remaining -= data.len
    r.chunkRemaining = 0
    discard r.sock.recvLine(timeout = r.timeoutMs)  # trailing CRLF after chunk data
  else:
    let data = r.sock.recv(4096, timeout = r.timeoutMs)
    if data.len == 0:
      r.eof = true
      return
    r.pending.add(data)

proc nextLine(r: var BodyReader): tuple[line: string, hasData: bool] =
  ## Returns the next logical line (terminator stripped). `hasData` is
  ## false only once the body is fully drained — a genuine blank line is
  ## returned as `("", true)`, distinct from end-of-body `("", false)`.
  while true:
    let idx = r.pending.find('\n')
    if idx >= 0:
      var line = r.pending[0 ..< idx]
      if line.len > 0 and line[^1] == '\r':
        line.setLen(line.len - 1)
      r.pending = r.pending[idx + 1 .. ^1]
      return (line, true)
    if r.eof:
      if r.pending.len > 0:
        let line = r.pending
        r.pending = ""
        return (line, true)
      return ("", false)
    fillMore(r)

proc chatCompletionStream*(
    client: LLMClient;
    prompt: string;
    history: seq[ChatMessage] = @[];
    extraParams: Table[string, JsonNode] = initTable[string, JsonNode]();
    onEvent: OnStreamEvent;
): ChatResponse =
  ## Streaming variant of chatCompletion. Sends `stream: true`, reads SSE
  ## events via a raw socket, invokes `onEvent` for each delta, and returns
  ## the aggregated ChatResponse. Uses the full client.timeoutMs as the
  ## socket receive timeout.
  ##
  ## The existing `chatCompletion` remains for non-streaming use and
  ## for callers that don't pass a stream callback.
  var messages = history
  if prompt.len > 0:
    messages.add(ChatMessage(role: crUser, content: prompt))

  var reqBody = buildRequestBody(client, messages, extraParams)
  reqBody["stream"] = %true

  let jsonBody = $reqBody
  let url = client.baseUrl & "/chat/completions"

  # ---------- Parse URL ----------
  let parsed = parseUri(url)
  let host = parsed.hostname
  let useSsl = parsed.scheme == "https"
  let portNum =
    if parsed.port.len > 0: parseInt(parsed.port)
    elif useSsl: 443
    else: 80
  let path =
    if parsed.path.len > 0: parsed.path
    else: "/"
  let queryPart = if parsed.query.len > 0: "?" & parsed.query else: ""

  # ---------- Build HTTP request ----------
  var req: string
  req.add("POST " & path & queryPart & " HTTP/1.1\r\n")
  req.add("Host: " & host & "\r\n")
  req.add("Content-Type: application/json\r\n")
  req.add("Accept: text/event-stream\r\n")
  req.add("User-Agent: talos-agent/0.1\r\n")
  if client.apiKey.len > 0:
    req.add("Authorization: Bearer " & client.apiKey & "\r\n")
  req.add("Content-Length: " & $jsonBody.len & "\r\n")
  req.add("Connection: close\r\n")
  req.add("\r\n")
  req.add(jsonBody)

  # ---------- Connect ----------
  var sock = newSocket()
  defer: sock.close()
  if useSsl:
    when defined(ssl):
      let ctx = newContext()
      wrapSocket(ctx, sock)
    else:
      raise newException(NetworkError,
        "HTTPS requested but compiled without -d:ssl")
  sock.connect(host, Port(portNum))
  sock.send(req)

  # ---------- Read response headers ----------
  # `recvLine` pads a genuine blank line to "\r\n" (2 chars) specifically so
  # it's distinguishable from disconnection, which yields "" (0 chars). The
  # end-of-headers separator is therefore `line == "\r\n"`, not `line.len == 0`.
  var statusLine = ""
  var status = 0
  var headers = initTable[string, string]()
  while true:
    let line = sock.recvLine(timeout = client.timeoutMs)
    if line.len == 0:
      raise newException(NetworkError, "connection closed while reading response headers")
    if statusLine.len == 0:
      statusLine = line
      # The raw status line is "HTTP/1.1 200 OK"; parseStatusCode expects
      # the "200 OK" part (matching how httpclient.Response.status is
      # already stripped of its version prefix for the other call site).
      let spaceIdx = statusLine.find(' ')
      let codeAndReason = if spaceIdx >= 0: statusLine[spaceIdx + 1 .. ^1] else: statusLine
      status = parseStatusCode(codeAndReason)
      continue
    if line == "\r\n":
      break  # end of headers
    let idx = line.find(':')
    if idx > 0:
      headers[line[0 ..< idx].strip().toLowerAscii()] = line[idx + 1 .. ^1].strip()

  let chunked = "chunked" in headers.getOrDefault("transfer-encoding", "").toLowerAscii()
  var reader = BodyReader(sock: sock, chunked: chunked, timeoutMs: client.timeoutMs)

  if status != 200:
    # Read error body
    var errBody = ""
    try:
      while true:
        let (line, hasData) = reader.nextLine()
        if not hasData: break
        errBody.add(line)
        errBody.add("\n")
    except CatchableError:
      discard
    raiseForStatus(status, errBody)

  # ---------- Parse SSE stream ----------
  result = ChatResponse()
  var contentBuf = ""
  var toolCallDeltas: seq[JsonNode] = @[]
  var dataBuf = ""
  var sawDone = false

  while not sawDone:
    let (line, hasData) = reader.nextLine()
    if not hasData:
      # EOF — stream ended without [DONE]. Treat as finish.
      break

    if line.startsWith("data:"):
      dataBuf = line[5..^1].strip()
    elif line.len == 0:
      # Blank line after data — process the event
      if dataBuf.len > 0:
        if dataBuf == "[DONE]":
          sawDone = true
        else:
          try:
            let node = parseJson(dataBuf)
            if node.hasKey("choices") and node["choices"].kind == JArray and
               node["choices"].len > 0:
              let choice = node["choices"][0]

              # --- Track finish_reason ---
              if choice.hasKey("finish_reason") and
                 not choice["finish_reason"].isNil and
                 choice["finish_reason"].kind == JString:
                let fr = choice["finish_reason"].getStr()
                if fr.len > 0:
                  result.finishReason = fr

              if choice.hasKey("delta") and choice["delta"].kind == JObject:
                let delta = choice["delta"]

                # --- Content delta ---
                if delta.hasKey("content") and delta["content"].kind == JString:
                  let c = delta["content"].getStr()
                  contentBuf.add(c)
                  if onEvent != nil:
                    var ev = ChatCompletionStreamEvent(kind: sekContent, delta: c)
                    onEvent(ev)

                # --- Tool call deltas ---
                if delta.hasKey("tool_calls") and delta["tool_calls"].kind == JArray:
                  for tcNode in delta["tool_calls"]:
                    toolCallDeltas.add(tcNode)
                    if onEvent != nil:
                      var ev = ChatCompletionStreamEvent(kind: sekToolCallDelta)
                      if tcNode.hasKey("index") and tcNode["index"].kind == JInt:
                        ev.toolCallId = $tcNode["index"].getInt()
                      if tcNode.hasKey("id") and tcNode["id"].kind == JString:
                        ev.toolCallId = tcNode["id"].getStr()
                      if tcNode.hasKey("function") and tcNode["function"].kind == JObject:
                        let fn = tcNode["function"]
                        if fn.hasKey("name") and fn["name"].kind == JString:
                          ev.toolName = fn["name"].getStr()
                        if fn.hasKey("arguments") and fn["arguments"].kind == JString:
                          ev.delta = fn["arguments"].getStr()
                      onEvent(ev)

            # --- Usage (arrives in final chunk) ---
            if node.hasKey("usage") and node["usage"].kind == JObject:
              let u = node["usage"]
              if u.hasKey("prompt_tokens") and u["prompt_tokens"].kind == JInt:
                result.usage.promptTokens = u["prompt_tokens"].getInt()
              if u.hasKey("completion_tokens") and u["completion_tokens"].kind == JInt:
                result.usage.completionTokens = u["completion_tokens"].getInt()
              if u.hasKey("total_tokens") and u["total_tokens"].kind == JInt:
                result.usage.totalTokens = u["total_tokens"].getInt()

            # --- Model ---
            if node.hasKey("model") and node["model"].kind == JString:
              result.model = node["model"].getStr()

          except JsonParsingError:
            discard  # Skip malformed SSE data lines

        dataBuf = ""
    # else: non-data, non-blank line — ignore (comments, etc.)

  # ---------- Emit finish event ----------
  if onEvent != nil:
    var ev = ChatCompletionStreamEvent(
      kind: sekFinish,
      finishReason: result.finishReason,
      usage: result.usage,
    )
    onEvent(ev)

  # ---------- Aggregate tool calls ----------
  result.content = contentBuf
  result.toolCalls = aggregateStreamingToolCalls(toolCallDeltas)
  result.raw = %*{"streamed": true}
