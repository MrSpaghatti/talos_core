## Mock MCP HTTP server for testing.
##
## Uses the same `asynchttpserver` pattern as `mock_server.nim`.
## Tests must use `asynchttpclient` to communicate with it.
##
## Pattern: create -> configure -> waitFor start() -> test -> stop().

import std/[asynchttpserver, asyncdispatch, json, strutils]

type
  MockMcpServer* = ref object
    server*: AsyncHttpServer
    port*: int
    requestCount*: int
    initializeBody: string
    toolsListBody: string
    toolCallBody: string
    unknownMethodBody: string
    httpErrorCode: int
    sseBody: string          ## raw text/event-stream body served on GET /sse
    sseRequestCount*: int
    lastLastEventIdHeader*: string  ## Last-Event-Id header on the most recent GET /sse

proc newMockMcpServer*(): MockMcpServer =
  new result
  result.server = newAsyncHttpServer()
  result.port = 0
  result.requestCount = 0
  result.httpErrorCode = 0
  result.initializeBody = """{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"mock-mcp","version":"1.0.0"}}}"""
  result.toolsListBody = """{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"""
  result.toolCallBody = """{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"mock result"}]}}"""
  result.unknownMethodBody = """{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"""
  result.sseBody = ""
  result.sseRequestCount = 0
  result.lastLastEventIdHeader = ""

proc setInitializeResponse*(self: MockMcpServer; version: string) =
  self.initializeBody = """{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"""" & version & """","capabilities":{},"serverInfo":{"name":"mock-mcp","version":"1.0.0"}}}"""

proc setInitializeError*(self: MockMcpServer; code: int; msg: string) =
  self.initializeBody = """{"jsonrpc":"2.0","id":1,"error":{"code":""" & $code & ""","message":"""" & msg & """"}}"""

proc setToolsList*(self: MockMcpServer; toolsJson: string) =
  self.toolsListBody = """{"jsonrpc":"2.0","id":1,"result":{"tools":""" & toolsJson & """}}"""

proc addTool*(self: MockMcpServer; name, description: string;
              inputSchema: string = "") =
  ## Appends a tool definition to the tools/list response.
  let schemaPart = if inputSchema.len > 0: inputSchema else: """{"type":"object"}"""
  let toolJson = """{"name":"""" & name & """","description":"""" & description &
                  """","inputSchema":""" & schemaPart & """}"""
  if self.toolsListBody == """{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}""":
    self.toolsListBody = """{"jsonrpc":"2.0","id":1,"result":{"tools":[""" & toolJson & """]}}"""
  else:
    self.toolsListBody = self.toolsListBody[0..^4] & ", " & toolJson & """]}}"""

proc setToolCallResult*(self: MockMcpServer; text: string) =
  self.toolCallBody = """{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"""" & text & """"}]}}"""

proc setToolCallError*(self: MockMcpServer; code: int; msg: string) =
  self.toolCallBody = """{"jsonrpc":"2.0","id":1,"error":{"code":""" & $code & ""","message":"""" & msg & """"}}"""

proc setHttpError*(self: MockMcpServer; code: int) =
  self.httpErrorCode = code

proc url*(self: MockMcpServer): string =
  if self.port == 0:
    "http://localhost:19999/mcp"
  else:
    "http://localhost:" & $self.port & "/mcp"

proc sseUrl*(self: MockMcpServer): string =
  if self.port == 0:
    "http://localhost:19999/sse"
  else:
    "http://localhost:" & $self.port & "/sse"

proc addSseEvent*(self: MockMcpServer; eventType, data: string; id: string = "") =
  ## Appends one SSE-framed event to the body served on GET /sse.
  if eventType.len > 0:
    self.sseBody.add("event: " & eventType & "\n")
  if id.len > 0:
    self.sseBody.add("id: " & id & "\n")
  for line in data.splitLines():
    self.sseBody.add("data: " & line & "\n")
  self.sseBody.add("\n")

proc clearSseEvents*(self: MockMcpServer) =
  self.sseBody = ""

proc getMethodName(body: string): string =
  if body.len == 0: return ""
  try:
    let node = parseJson(body)
    if node.hasKey("method") and node["method"].kind == JString:
      return node["method"].getStr()
  except JsonParsingError:
    discard
  result = ""

proc handleRequest*(self: MockMcpServer; req: Request) {.async.} =
  if req.reqMethod == HttpGet and req.url.path.endsWith("/sse"):
    self.sseRequestCount += 1
    self.lastLastEventIdHeader = req.headers.getOrDefault("Last-Event-Id")
    let headers = newHttpHeaders([("Content-Type", "text/event-stream")])
    await req.respond(Http200, self.sseBody, headers)
    return

  self.requestCount += 1
  if self.httpErrorCode > 0:
    await req.respond(HttpCode(self.httpErrorCode),
                      """{"error":"mock error"}""",
                      newHttpHeaders([("Content-Type", "application/json")]))
    return
  if req.reqMethod != HttpPost:
    await req.respond(Http405, "Method Not Allowed")
    return
  let body = req.body
  let methodName = getMethodName(body)
  var respBody: string
  case methodName
  of "initialize":         respBody = self.initializeBody
  of "tools/list":         respBody = self.toolsListBody
  of "tools/call":         respBody = self.toolCallBody
  of "notifications/initialized": respBody = ""
  else:                    respBody = self.unknownMethodBody
  let headers = newHttpHeaders([("Content-Type", "application/json")])
  await req.respond(Http200, respBody, headers)

proc acceptLoop(self: MockMcpServer) {.async.} =
  ## `acceptRequest` accepts a single connection and returns — its own
  ## docstring says to loop around it. Needed for real multi-connection
  ## traffic (e.g. an SSE client reconnecting), not just one request ever.
  ## Exits cleanly when `stop()` closes the listening socket.
  while true:
    try:
      await self.server.acceptRequest(
        proc (req: Request) {.async.} = await self.handleRequest(req)
      )
    except CatchableError:
      break

proc start*(self: MockMcpServer) {.async.} =
  self.server.listen(Port(0))
  self.port = self.server.getPort().int
  asyncCheck self.acceptLoop()

proc stop*(self: MockMcpServer) =
  self.server.close()
