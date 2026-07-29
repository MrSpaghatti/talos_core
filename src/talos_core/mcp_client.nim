## MCP client — Model Context Protocol tool discovery.
##
## MCP (https://modelcontextprotocol.io/) is a JSON-RPC-based protocol for
## exposing tools from external servers to an LLM. This client implements the
## subset needed for the Talos use case:
##   - HTTP/SSE transport (server-driven streaming via Server-Sent Events)
##   - `initialize` handshake (protocol version negotiation)
##   - `tools/list` — discover all tools available on a server
##   - `tools/call` — invoke a tool and return its result
##
## Tools discovered from MCP servers are not registered automatically. Call
## `discoverTools()` to get a sequence of `McpTool` objects, then pass them
## to `registerMcpTool()` in `mcp_tool.nim` to add them to a `ToolRegistry`.

import std/[httpclient, json, times, strutils, os, asyncdispatch, asyncstreams]

import talos_core/config
import util

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  McpTool* = object
    ## A tool as returned by the MCP server's `tools/list` response.
    server*: string           ## Originating server name (from config).
    name*: string             ## Unique name, e.g. "filesystem_read"
    description*: string      ## Human-readable description.
    inputSchema*: JsonNode    ## JSON Schema for tool arguments.

  McpClient* = ref object
    ## Per-server MCP client state.
    cfg*: McpServerConfig
    http*: HttpClient
    protocolVersion*: string   ## Negotiated during initialize.

  McpError* = object of CatchableError
    ## Base type for MCP-level errors.
    serverUrl*: string

  McpConnectionError* = object of McpError
    ## Could not reach the MCP server or complete the handshake.
  McpProtocolError* = object of McpError
    ## Server returned an error or unexpected response.
  McpToolNotFoundError* = object of McpError
    ## Server does not have a tool with the given name.

const
  DefaultMcpTimeoutMs* = 30_000
  DefaultMcpServerUrl* = "http://localhost:8080/mcp"

# ---------------------------------------------------------------------------
# Client construction
# ---------------------------------------------------------------------------

proc newMcpServerConfig*(
  url: string = DefaultMcpServerUrl;
  authToken: string = "";
  timeoutMs: int = DefaultMcpTimeoutMs;
  enabled: bool = true;
): McpServerConfig =
  McpServerConfig(
    url: url.strip(trailing = true, chars = {'/'}),
    authToken: authToken,
    timeoutMs: if timeoutMs <= 0: DefaultMcpTimeoutMs else: timeoutMs,
    enabled: enabled,
  )

proc newMcpClient*(cfg: McpServerConfig): McpClient =
  let http = newHttpClient(timeout = cfg.timeoutMs)
  if cfg.authToken.len > 0:
    http.headers = newHttpHeaders({"Authorization": "Bearer " & cfg.authToken})
  result = new McpClient
  result.cfg = cfg
  result.http = http
  result.protocolVersion = ""

# ---------------------------------------------------------------------------
# JSON-RPC helpers
# ---------------------------------------------------------------------------

proc jsonRpcRequest*(mcpMethod: string; params: JsonNode = nil): JsonNode =
  result = newJObject()
  result["jsonrpc"] = %"2.0"
  result["id"] = %(getTime().toUnix())
  result["method"] = %mcpMethod
  if not params.isNil:
    result["params"] = params
  else:
    result["params"] = newJObject()

proc jsonRpcResponseId*(node: JsonNode): int =
  if not node.isNil and node.kind == JObject and node.hasKey("id"):
    result = node["id"].getInt()
  else:
    result = 0

proc jsonRpcError(msg: string; code: int; data: JsonNode = nil): JsonNode =
  result = newJObject()
  result["jsonrpc"] = %"2.0"
  result["id"] = newJNull()
  result["error"] = newJObject()
  result["error"]["message"] = %msg
  result["error"]["code"] = newJInt(code)

# ---------------------------------------------------------------------------
# HTTP transport
# ---------------------------------------------------------------------------

proc callMethod*(client: McpClient; mcpMethod: string; params: JsonNode = nil): JsonNode =
  ## Sends a JSON-RPC request to the MCP server and returns the parsed response.
  ## Raises on transport errors, HTTP errors, or JSON-RPC error responses.
  let reqBody = jsonRpcRequest(mcpMethod, params)

  var response: Response
  try:
    response = client.http.request(
      client.cfg.url,
      httpMethod = HttpPost,
      body = $reqBody,
      headers = newHttpHeaders({"Content-Type": "application/json"}),
    )
  except CatchableError as e:
    var err = newException(McpConnectionError,
      "failed to connect to MCP server '" & client.cfg.url & "': " & e.msg)
    err.serverUrl = client.cfg.url
    raise err

  let statusCode = parseStatusCode(response.status)
  if statusCode >= 400:
    var err = newException(McpConnectionError,
      "MCP server returned HTTP " & $statusCode &
      " at '" & client.cfg.url & "': " & response.body)
    err.serverUrl = client.cfg.url
    raise err

  var respNode: JsonNode
  try:
    respNode = parseJson(response.body)
  except JsonParsingError as e:
    var err = newException(McpProtocolError,
      "MCP server at '" & client.cfg.url &
      "' returned invalid JSON: " & e.msg)
    err.serverUrl = client.cfg.url
    raise err

  # Check for JSON-RPC error response. Per spec `error` should always be an
  # object, but a malformed/malicious server could send a bare string or
  # other non-object value — guard against that before calling `.hasKey`/
  # indexing into it, which otherwise raises an uncatchable AssertionDefect.
  if respNode.kind == JObject and respNode.hasKey("error"):
    let errNode = respNode["error"]
    let errMsg =
      if errNode.kind == JObject and errNode.hasKey("message"):
        errNode["message"].getStr()
      else:
        "malformed JSON-RPC error object: " & $errNode
    let errCode =
      if errNode.kind == JObject and errNode.hasKey("code"):
        errNode["code"].getInt()
      else:
        -1
    var err = newException(McpProtocolError,
      "MCP server '" & client.cfg.url &
      "' returned JSON-RPC error [" & $errCode & "]: " & errMsg)
    err.serverUrl = client.cfg.url
    raise err

  # Only ever return an object: every caller goes on to call `.hasKey` on
  # this node, which raises an uncatchable AssertionDefect on any other
  # JSON kind (e.g. a server responding with a bare string or array).
  if respNode.kind != JObject:
    var err = newException(McpProtocolError,
      "MCP server at '" & client.cfg.url &
      "' returned a non-object JSON-RPC response: " & $respNode)
    err.serverUrl = client.cfg.url
    raise err

  respNode

# ---------------------------------------------------------------------------
# MCP protocol methods
# ---------------------------------------------------------------------------

proc initialize*(client: McpClient; serverName: string = "talos"): string =
  ## Sends the MCP `initialize` handshake. Sets `client.protocolVersion`
  ## and returns the server's capabilities. Raises on failure.
  let params = newJObject()
  params["protocolVersion"] = %"2024-11-05"
  params["clientInfo"] = newJObject()
  params["clientInfo"]["name"] = %"talos-agent"
  params["clientInfo"]["version"] = %"0.1.0"
  params["clientInfo"]["meta"] = newJObject()
  params["clientInfo"]["meta"]["hostname"] = %getEnv("HOSTNAME", "unknown")

  var resp: JsonNode
  try:
    resp = callMethod(client, "initialize", params)
  except McpError:
    raise
  except CatchableError as e:
    var err = newException(McpConnectionError,
      "MCP initialize failed: " & e.msg)
    err.serverUrl = client.cfg.url
    raise err

  if not resp.hasKey("result"):
    raise newException(McpProtocolError,
      "initialize response missing 'result' field at '" & client.cfg.url & "'")

  let initResult = resp["result"]
  if initResult.kind != JObject:
    raise newException(McpProtocolError,
      "initialize response 'result' is not an object at '" & client.cfg.url & "'")
  if initResult.hasKey("protocolVersion") and initResult["protocolVersion"].kind == JString:
    client.protocolVersion = initResult["protocolVersion"].getStr()
  else:
    raise newException(McpProtocolError,
      "initialize response missing protocolVersion at '" & client.cfg.url & "'")

  # Send "initialized" notification (no response expected).
  # Best-effort: wrap in try/except so a dropped connection doesn't crash.
  let notif = jsonRpcRequest("notifications/initialized", newJObject())
  try:
    discard client.http.request(
      client.cfg.url,
      httpMethod = HttpPost,
      body = $notif,
      headers = newHttpHeaders({"Content-Type": "application/json"}),
    )
  except CatchableError:
    discard  # notification is best-effort per JSON-RPC spec
  client.protocolVersion

proc listTools*(client: McpClient): seq[McpTool] =
  ## Asks the MCP server for all available tools and returns them.
  result = @[]
  var resp: JsonNode
  try:
    resp = callMethod(client, "tools/list")
  except McpError:
    raise
  except CatchableError as e:
    var err = newException(McpConnectionError,
      "tools/list failed: " & e.msg)
    err.serverUrl = client.cfg.url
    raise err

  if not resp.hasKey("result"):
    raise newException(McpProtocolError,
      "tools/list response missing 'result' at '" & client.cfg.url & "'")

  let resultNode = resp["result"]
  # A non-object "result" (e.g. {"result":"oops"}) means no tools — .hasKey
  # on it would raise an uncatchable AssertionDefect.
  if resultNode.kind == JObject and
      resultNode.hasKey("tools") and resultNode["tools"].kind == JArray:
    for toolNode in resultNode["tools"]:
      if toolNode.kind != JObject:
        continue
      var tool = McpTool(
        server: client.cfg.url,
        name: if toolNode.hasKey("name"): toolNode["name"].getStr() else: "",
        description: if toolNode.hasKey("description"): toolNode["description"].getStr() else: "",
        inputSchema: if toolNode.hasKey("inputSchema"): toolNode["inputSchema"] else: newJObject(),
      )
      if tool.name.len > 0:
        result.add(tool)

proc callTool*(client: McpClient; toolName: string; args: JsonNode): string =
  ## Calls a tool on the MCP server and returns the result as a string.
  ## Raises `McpToolNotFoundError` if the server doesn't know the tool.
  let params = newJObject()
  params["name"] = %toolName
  params["arguments"] = if args.isNil: newJObject() else: args

  var resp: JsonNode
  try:
    resp = callMethod(client, "tools/call", params)
  except McpError:
    raise
  except CatchableError as e:
    var err = newException(McpConnectionError,
      "tools/call failed: " & e.msg)
    err.serverUrl = client.cfg.url
    raise err

  if not resp.hasKey("result"):
    raise newException(McpProtocolError,
      "tools/call response missing 'result' at '" & client.cfg.url & "'")

  let resultNode = resp["result"]
  # MCP result format: { "content": [{ "type": "text", "text": "..." }] }
  # Guard the kind first: .hasKey on a non-object "result" raises an
  # uncatchable AssertionDefect; the pretty() fallback below handles it.
  if resultNode.kind == JObject and
      resultNode.hasKey("content") and resultNode["content"].kind == JArray:
    var parts: seq[string] = @[]
    for content in resultNode["content"]:
      if content.kind == JObject and content.hasKey("text"):
        parts.add(content["text"].getStr())
    return parts.join("\n")
  # Fallback: return the result as a JSON string.
  return resultNode.pretty()

# ---------------------------------------------------------------------------
# Convenience: discover all tools from a list of server configs
# ---------------------------------------------------------------------------

proc discoverTools*(configs: seq[McpServerConfig]): seq[McpTool] =
  ## Connects to each server in `configs`, discovers its tools, and returns
  ## the union of all tools. Skips servers where `enabled == false` or
  ## connection fails (logs a warning internally; caller decides how to handle).
  result = @[]
  for cfg in configs:
    if not cfg.enabled:
      continue
    var client = newMcpClient(cfg)
    defer: client.http.close()
    try:
      discard initialize(client)
      let tools = client.listTools()
      for tool in tools:
        # TODO: prefix tool.name with a server-derived namespace to avoid
        # collisions when multiple MCP servers expose tools with the same name.
        result.add(tool)
    except CatchableError as e:
      # Connection failed — log and continue with remaining servers.
      stderr.writeLine("Warning: MCP server '" & cfg.url &
                       "' unavailable: " & e.msg)
      continue

# ---------------------------------------------------------------------------
# SSE / streaming transport
# ---------------------------------------------------------------------------
##
## Runs on `AsyncHttpClient` (separate from the synchronous `HttpClient`
## used above for tools/list and tools/call), since an SSE connection stays
## open indefinitely and needs to be read incrementally as data arrives —
## `AsyncHttpClient.request()` returns as soon as headers are parsed and
## streams the body into `AsyncResponse.bodyStream` in the background
## (confirmed via std/httpclient's `parseResponse`: for AsyncHttpClient it
## kicks off `parseBody` as a background future rather than awaiting it),
## so an indefinite connection with no Content-Length doesn't block here
## the way it would on the sync client.

type
  McpSseEvent* = object
    eventType*: string        ## "message" if the server didn't set one
    data*: string
    id*: string                ## empty if the server didn't set one

  McpSseCallback* = proc(event: McpSseEvent) {.gcsafe, raises: [].}

  SseParser* = object
    ## Incremental SSE (text/event-stream) parser. Feed it raw byte chunks
    ## as they arrive off the wire — chunk boundaries don't have to align
    ## with line or event boundaries, `feed` buffers correctly across calls.
    buf: string
    evType: string
    evData: seq[string]
    evId: string

  McpStreamingClient* = ref object
    http*: AsyncHttpClient
    baseUrl*: string           ## e.g. "http://localhost:8080/sse"
    authToken*: string
    onEvent*: McpSseCallback
    running*: bool
    lastEventId*: string

proc newSseParser*(): SseParser =
  SseParser(buf: "", evType: "", evData: @[], evId: "")

proc feed*(p: var SseParser; chunk: string): seq[McpSseEvent] =
  ## Feeds a raw chunk of the response body into the parser. Returns every
  ## complete event dispatched as a result (usually 0 or 1, but a chunk can
  ## contain more than one blank-line-terminated event at once).
  result = @[]
  p.buf.add(chunk)
  while true:
    let nlIdx = p.buf.find('\n')
    if nlIdx < 0:
      break
    var line = p.buf[0 ..< nlIdx]
    p.buf = p.buf[nlIdx + 1 .. ^1]
    if line.len > 0 and line[^1] == '\r':
      line = line[0 ..< line.len - 1]

    if line.len == 0:
      # Blank line: dispatch the event accumulated so far (per the SSE
      # spec, an event with no "data:" lines at all is not dispatched).
      if p.evData.len > 0:
        result.add(McpSseEvent(
          eventType: (if p.evType.len > 0: p.evType else: "message"),
          data: p.evData.join("\n"),
          id: p.evId,
        ))
      p.evType = ""
      p.evData = @[]
      p.evId = ""
    elif line[0] == ':':
      discard  # comment / heartbeat line — ignored per spec
    elif line.startsWith("event:"):
      p.evType = line["event:".len .. ^1].strip()
    elif line.startsWith("data:"):
      p.evData.add(line["data:".len .. ^1].strip())
    elif line.startsWith("id:"):
      p.evId = line["id:".len .. ^1].strip()
    elif line.startsWith("retry:"):
      discard  # reconnection-delay hint — not used, McpStreamingClient
               # has its own fixed reconnect backoff (see `run`)
    else:
      discard  # unknown field name — ignored per spec

proc newMcpStreamingClient*(
    baseUrl: string;
    authToken: string = "";
    onEvent: McpSseCallback = nil;
): McpStreamingClient =
  McpStreamingClient(
    http: newAsyncHttpClient(),
    baseUrl: baseUrl.strip(trailing = true, chars = {'/'}),
    authToken: authToken,
    onEvent: onEvent,
    running: false,
    lastEventId: "",
  )

proc listen*(client: McpStreamingClient): Future[void] {.async.} =
  ## Connects to the SSE endpoint and dispatches events via `onEvent` until
  ## `stop()` is called or the connection is closed by the server. Does not
  ## reconnect on disconnect — see `run()` for a reconnecting wrapper.
  if not client.http.isNil:
    try: client.http.close()
    except CatchableError: discard
  client.http = newAsyncHttpClient()
  client.http.headers = newHttpHeaders({
    "Accept": "text/event-stream",
    "Cache-Control": "no-cache",
    # Each listen() call is a fresh, independent connection — SSE
    # "reconnect" means exactly that, not multiplexing a request onto a
    # kept-alive socket. Forcing this explicitly also sidesteps
    # asynchttpclient/asynchttpserver keep-alive edge cases where a second
    # request on a reused connection silently never reaches the server.
    "Connection": "close",
  })
  if client.authToken.len > 0:
    client.http.headers["Authorization"] = "Bearer " & client.authToken
  if client.lastEventId.len > 0:
    client.http.headers["Last-Event-Id"] = client.lastEventId

  let resp = await client.http.request(client.baseUrl, httpMethod = HttpGet)
  var parser = newSseParser()
  client.running = true
  while client.running:
    let (hasData, chunk) = await resp.bodyStream.read()
    if not hasData:
      break
    for event in parser.feed(chunk):
      if event.id.len > 0:
        client.lastEventId = event.id
      if not client.onEvent.isNil:
        client.onEvent(event)

proc run*(client: McpStreamingClient; reconnectDelayMs: int = 1000): Future[void] {.async.} =
  ## Runs `listen()` in a loop, reconnecting (carrying `Last-Event-Id`
  ## forward for resume) on any disconnect, until `stop()` is called.
  client.running = true
  while client.running:
    try:
      await client.listen()
    except CatchableError:
      discard
    if client.running:
      await sleepAsync(reconnectDelayMs)

proc stop*(client: McpStreamingClient) =
  client.running = false
  try:
    client.http.close()
  except CatchableError:
    discard