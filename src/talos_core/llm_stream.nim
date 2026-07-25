## Streaming (SSE) chat completion client.
##
## Extracted from `llm_client.nim` to separate the raw-socket SSE
## streaming implementation from the synchronous HTTP client. The stream
## event types (`StreamEventKind`, `ChatCompletionStreamEvent`,
## `OnStreamEvent`) remain in `llm_client.nim` as part of the public API.

import std/[json, strutils, tables, net, uri, algorithm]
import util
import llm_client

# ---------------------------------------------------------------------------
# Streaming tool call aggregation
# ---------------------------------------------------------------------------

proc aggregateStreamingToolCalls(deltas: seq[JsonNode]): seq[ToolCall] =
  ## Aggregates streaming tool_call deltas into a final list of ToolCalls.
  ## OpenAI streams tool calls as incremental updates keyed by index.
  result = @[]
  var byIndex = initTable[int, tuple[id, name, args: string]]()
  for node in deltas:
    if node.isNil or node.kind != JObject:
      # .hasKey on a non-object delta raises an uncatchable AssertionDefect
      continue
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

# ---------------------------------------------------------------------------
# Raw-socket network helpers
# ---------------------------------------------------------------------------

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

proc recvLineNet(sock: Socket; timeoutMs: int): string =
  ## `recvLine` with socket failures rewrapped as NetworkError, so the
  ## streaming path surfaces the same typed errors callers of this module
  ## already handle from the non-streaming path (see doRequest) — instead
  ## of leaking raw OSError/TimeoutError from a mid-stream connection drop.
  try:
    sock.recvLine(timeout = timeoutMs)
  except OSError as e:
    raise newException(NetworkError, "socket error during streaming: " & e.msg)
  except TimeoutError as e:
    raise newException(NetworkError, "socket timeout during streaming: " & e.msg)
  except IOError as e:
    raise newException(NetworkError, "I/O error during streaming: " & e.msg)

proc recvNet(sock: Socket; size: int; timeoutMs: int): string =
  ## `recv` with the same NetworkError rewrapping as recvLineNet.
  try:
    sock.recv(size, timeout = timeoutMs)
  except OSError as e:
    raise newException(NetworkError, "socket error during streaming: " & e.msg)
  except TimeoutError as e:
    raise newException(NetworkError, "socket timeout during streaming: " & e.msg)
  except IOError as e:
    raise newException(NetworkError, "I/O error during streaming: " & e.msg)

const MaxChunkSize* = 8 * 1024 * 1024
  ## Upper bound on a single chunked-transfer chunk. SSE events from an LLM
  ## are a few KiB; anything approaching this is a broken or hostile server.

proc parseChunkSize*(sizeLine: string): int =
  ## Parses an HTTP chunked-transfer chunk-size line (hex digits, optional
  ## ";extension"). Raises `ProtocolError` for a malformed, negative, or
  ## oversized size.
  ##
  ## The length check must come BEFORE parseHexInt: parseHexInt has no
  ## overflow check and wraps mod 2^64, so an oversized line can land on a
  ## small *positive* value (parseHexInt("10000000000000005") == 5) — a
  ## sign check after the fact catches only some wraps. The size cap also
  ## bounds the eager `setLen(size)` allocation inside `Socket.recv`, which
  ## would otherwise attempt a multi-GB allocation from one crafted header
  ## line before any body bytes arrive.
  let hexPart = block:
    let semiIdx = sizeLine.find(';')
    (if semiIdx >= 0: sizeLine[0 ..< semiIdx] else: sizeLine).strip()
  if hexPart.len == 0 or hexPart.len > 7:  # 7 hex digits = max 256 MiB-1
    raise newException(ProtocolError,
      "invalid chunked-transfer size line: " & sizeLine.strip())
  var size = 0
  try:
    size = parseHexInt(hexPart)
  except ValueError:
    raise newException(ProtocolError,
      "invalid chunked-transfer size line: " & sizeLine.strip())
  if size > MaxChunkSize:
    raise newException(ProtocolError,
      "chunked-transfer chunk of " & $size & " bytes exceeds the " &
      $MaxChunkSize & "-byte limit")
  size

proc fillMore(r: var BodyReader) =
  if r.eof:
    return
  if r.chunked:
    if r.chunkRemaining == 0:
      let sizeLine = recvLineNet(r.sock, r.timeoutMs)
      if sizeLine.len == 0:
        r.eof = true
        return
      let size = parseChunkSize(sizeLine)
      if size == 0:
        # Terminal chunk: consume optional trailer headers up to the
        # final blank line, then signal end of body.
        while true:
          let trailer = recvLineNet(r.sock, r.timeoutMs)
          if trailer.len == 0 or trailer == "\r\n":
            break
        r.eof = true
        return
      r.chunkRemaining = size
    var remaining = r.chunkRemaining
    while remaining > 0:
      let data = recvNet(r.sock, remaining, r.timeoutMs)
      if data.len == 0:
        r.eof = true
        return
      r.pending.add(data)
      remaining -= data.len
    r.chunkRemaining = 0
    discard recvLineNet(r.sock, r.timeoutMs)  # trailing CRLF after chunk data
  else:
    let data = recvNet(r.sock, 4096, r.timeoutMs)
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

# ---------------------------------------------------------------------------
# Streaming chat completion
# ---------------------------------------------------------------------------

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
    if parsed.port.len > 0:
      try: parseInt(parsed.port)
      except ValueError: raise newException(LLMError, "Invalid port in URL: " & parsed.port)
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
  try:
    sock.connect(host, Port(portNum))
    sock.send(req)
  except OSError as e:
    raise newException(NetworkError,
      "failed to connect for streaming: " & e.msg)
  except IOError as e:
    raise newException(NetworkError,
      "failed to connect for streaming: " & e.msg)

  # ---------- Read response headers ----------
  # `recvLine` pads a genuine blank line to "\r\n" (2 chars) specifically so
  # it's distinguishable from disconnection, which yields "" (0 chars). The
  # end-of-headers separator is therefore `line == "\r\n"`, not `line.len == 0`.
  var statusLine = ""
  var status = 0
  var headers = initTable[string, string]()
  while true:
    let line = recvLineNet(sock, client.timeoutMs)
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

  if not (status >= 200 and status < 300):
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
            # Every .hasKey below must be preceded by a kind == JObject
            # check on its node: a malformed SSE event (`data: "hello"`,
            # `{"choices":[null]}`, ...) otherwise raises an uncatchable
            # AssertionDefect — the `except JsonParsingError` here only
            # covers JSON *syntax* errors. The non-streaming parseResponse
            # already guards these; this path must match it.
            let node = parseJson(dataBuf)
            if node.kind == JObject and
               node.hasKey("choices") and node["choices"].kind == JArray and
               node["choices"].len > 0:
              let choice = node["choices"][0]

              # --- Track finish_reason ---
              if choice.kind == JObject and choice.hasKey("finish_reason") and
                 not choice["finish_reason"].isNil and
                 choice["finish_reason"].kind == JString:
                let fr = choice["finish_reason"].getStr()
                if fr.len > 0:
                  result.finishReason = fr

              if choice.kind == JObject and
                 choice.hasKey("delta") and choice["delta"].kind == JObject:
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
                    if tcNode.kind != JObject:
                      continue
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
            if node.kind == JObject and
               node.hasKey("usage") and node["usage"].kind == JObject:
              let u = node["usage"]
              if u.hasKey("prompt_tokens") and u["prompt_tokens"].kind == JInt:
                result.usage.promptTokens = u["prompt_tokens"].getInt()
              if u.hasKey("completion_tokens") and u["completion_tokens"].kind == JInt:
                result.usage.completionTokens = u["completion_tokens"].getInt()
              if u.hasKey("total_tokens") and u["total_tokens"].kind == JInt:
                result.usage.totalTokens = u["total_tokens"].getInt()

            # --- Model ---
            if node.kind == JObject and
               node.hasKey("model") and node["model"].kind == JString:
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
