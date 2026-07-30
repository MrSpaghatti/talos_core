## Tests for talos_core/mcp_client.nim

import std/[unittest, json, asyncdispatch, httpclient, strutils]
import talos_core/mcp_client
import talos_core/config
import mock_mcp_server
import talos_core/testkit/mock_llm_server

# ---------------------------------------------------------------------------
# Tests: config parsing
# ---------------------------------------------------------------------------

suite "mcp_server_config":
  test "default values":
    let cfg = newMcpServerConfig()
    check cfg.url == "http://localhost:8080/mcp"
    check cfg.authToken == ""
    check cfg.timeoutMs == 30_000
    check cfg.enabled == true

  test "custom values":
    let cfg = newMcpServerConfig(url = "https://mcp.example.com/api",
                                  authToken = "tok123",
                                  timeoutMs = 5000,
                                  enabled = false)
    check cfg.url == "https://mcp.example.com/api"
    check cfg.authToken == "tok123"
    check cfg.timeoutMs == 5000
    check cfg.enabled == false

  test "trailing slash stripped from url":
    let cfg = newMcpServerConfig(url = "http://localhost:8080/mcp/")
    check cfg.url == "http://localhost:8080/mcp"

  test "zero timeout reverts to default":
    let cfg = newMcpServerConfig(timeoutMs = 0)
    check cfg.timeoutMs == 30_000

# ---------------------------------------------------------------------------
# Tests: JSON-RPC helpers
# ---------------------------------------------------------------------------

suite "json_rpc helpers":
  test "jsonRpcRequest with params":
    let req = jsonRpcRequest("tools/list", %*{"verbose": true})
    check req["jsonrpc"].getStr() == "2.0"
    check req["method"].getStr() == "tools/list"
    check req["params"]["verbose"].getBool() == true

  test "jsonRpcRequest without params":
    let req = jsonRpcRequest("initialize")
    check req["jsonrpc"].getStr() == "2.0"
    check req["method"].getStr() == "initialize"
    check req["params"].kind == JObject

  test "jsonRpcResponseId extracts int id":
    let node = parseJson("""{"id":42,"result":{}}""")
    check jsonRpcResponseId(node) == 42

  test "jsonRpcResponseId returns 0 when missing":
    let node = parseJson("""{"result":{}}""")
    check jsonRpcResponseId(node) == 0

# ---------------------------------------------------------------------------
# Tests: McpTool type
# ---------------------------------------------------------------------------

## McpTool is a plain data object with no derived/computed fields — a
## "stores all fields" test would only prove Nim's object literal syntax
## works, so it's intentionally not covered here; `listTools` below proves
## McpTool values are actually populated correctly from server responses.

# ---------------------------------------------------------------------------
# Tests: McpError hierarchy
# ---------------------------------------------------------------------------

suite "mcp_error hierarchy":
  test "McpConnectionError has serverUrl and is a CatchableError/McpError":
    var err = newException(McpConnectionError, "connection refused")
    err.serverUrl = "http://localhost:9999"
    check err.serverUrl == "http://localhost:9999"
    check err of CatchableError
    check err of McpError

# ---------------------------------------------------------------------------
# Tests: McpClient construction
# ---------------------------------------------------------------------------

suite "mcp_client construction":
  test "newMcpClient sets protocolVersion to empty":
    let cfg = newMcpServerConfig()
    let client = newMcpClient(cfg)
    check client.protocolVersion == ""

  test "newMcpClient stores config":
    let cfg = newMcpServerConfig(url = "http://localhost:9000/mcp",
                                  timeoutMs = 15_000)
    let client = newMcpClient(cfg)
    check client.cfg.url == "http://localhost:9000/mcp"
    check client.cfg.timeoutMs == 15_000

# ---------------------------------------------------------------------------
# Tests: config integration -- McpServerConfig in TalosConfig
# ---------------------------------------------------------------------------

suite "config integration":
  test "TalosConfig.mcpServers is empty by default":
    let cfg = defaultConfig()
    check cfg.mcpServers.len == 0

  test "McpServerConfig fields accessible":
    let cfg = McpServerConfig(url: "http://test:9000", authToken: "secret",
                              timeoutMs: 5000, enabled: true)
    check cfg.url == "http://test:9000"
    check cfg.authToken == "secret"
    check cfg.timeoutMs == 5000
    check cfg.enabled == true

# ---------------------------------------------------------------------------
# Integration tests: async mock server x async HTTP client
# These verify the MCP protocol JSON-RPC messages are correctly
# constructed and parsed by communicating with a mock server.
# ---------------------------------------------------------------------------

proc mcpPost(cl: AsyncHttpClient; url: string; body: string): Future[AsyncResponse] =
  ## Helper: POST with Content-Type header.
  let hdrs = newHttpHeaders([("Content-Type", "application/json")])
  result = cl.request(url, httpMethod = HttpPost, body = body, headers = hdrs)

suite "mcp protocol integration":
  test "initialize returns protocol version":
    let mock = newMockMcpServer()
    mock.setInitializeResponse("2024-11-05")
    waitFor mock.start()
    defer: mock.stop()

    let cl = newAsyncHttpClient()
    let resp = waitFor mcpPost(cl, mock.url(), $jsonRpcRequest("initialize", newJObject()))
    let body = waitFor resp.body
    let json = parseJson(body)
    check json["result"]["protocolVersion"].getStr() == "2024-11-05"

  test "listTools returns tool definitions":
    let mock = newMockMcpServer()
    mock.addTool("read_file", "Read a file from disk")
    mock.addTool("write_file", "Write content to disk",
                 """{"type":"object","properties":{"path":{"type":"string"}}}""")
    waitFor mock.start()
    defer: mock.stop()

    let cl = newAsyncHttpClient()
    let resp = waitFor mcpPost(cl, mock.url(), $jsonRpcRequest("tools/list"))
    let body = waitFor resp.body
    let json = parseJson(body)
    check json["result"]["tools"].len == 2
    check json["result"]["tools"][0]["name"].getStr() == "read_file"
    check json["result"]["tools"][1]["name"].getStr() == "write_file"
    check json["result"]["tools"][1]["description"].getStr() == "Write content to disk"

  test "listTools empty when no tools registered":
    let mock = newMockMcpServer()
    waitFor mock.start()
    defer: mock.stop()

    let cl = newAsyncHttpClient()
    let resp = waitFor mcpPost(cl, mock.url(), $jsonRpcRequest("tools/list"))
    let body = waitFor resp.body
    let json = parseJson(body)
    check json["result"]["tools"].len == 0

  test "callTool returns text content":
    let mock = newMockMcpServer()
    mock.setToolCallResult("command output")
    waitFor mock.start()
    defer: mock.stop()

    let cl = newAsyncHttpClient()
    let resp = waitFor mcpPost(cl, mock.url(),
      $jsonRpcRequest("tools/call", %*{"name": "test", "arguments": {}}))
    let body = waitFor resp.body
    let json = parseJson(body)
    check json["result"]["content"][0]["text"].getStr() == "command output"

  test "initialize error returns JSON-RPC error":
    let mock = newMockMcpServer()
    mock.setInitializeError(-32603, "init failed")
    waitFor mock.start()
    defer: mock.stop()

    let cl = newAsyncHttpClient()
    let resp = waitFor mcpPost(cl, mock.url(), $jsonRpcRequest("initialize", newJObject()))
    let body = waitFor resp.body
    let json = parseJson(body)
    check json.hasKey("error")
    check json["error"]["message"].getStr() == "init failed"

  test "callTool error returns JSON-RPC error":
    let mock = newMockMcpServer()
    mock.setToolCallError(-32603, "tool error")
    waitFor mock.start()
    defer: mock.stop()

    let cl = newAsyncHttpClient()
    let resp = waitFor mcpPost(cl, mock.url(),
      $jsonRpcRequest("tools/call", %*{"name": "bad", "arguments": {}}))
    let body = waitFor resp.body
    let json = parseJson(body)
    check json.hasKey("error")
    check json["error"]["message"].getStr() == "tool error"

  test "HTTP error returns error response":
    let mock = newMockMcpServer()
    mock.setHttpError(500)
    waitFor mock.start()
    defer: mock.stop()

    let cl = newAsyncHttpClient()
    let resp = waitFor mcpPost(cl, mock.url(), $jsonRpcRequest("initialize"))
    check $resp.code == "500 Internal Server Error"

  test "unknown method returns method not found":
    let mock = newMockMcpServer()
    waitFor mock.start()
    defer: mock.stop()

    let cl = newAsyncHttpClient()
    let resp = waitFor mcpPost(cl, mock.url(), $jsonRpcRequest("unknown_method"))
    let body = waitFor resp.body
    let json = parseJson(body)
    check json["error"]["code"].getInt() == -32601

  test "request counter tracks requests":
    let mock = newMockMcpServer()
    waitFor mock.start()
    defer: mock.stop()

    let cl = newAsyncHttpClient()
    discard waitFor mcpPost(cl, mock.url(), $jsonRpcRequest("initialize"))
    discard waitFor mcpPost(cl, mock.url(), $jsonRpcRequest("tools/list"))
    check mock.requestCount == 2

# ---------------------------------------------------------------------------
# Real client round-trip tests
#
# Everything above drives the mock server directly over raw HTTP — it never
# calls mcp_client.nim's own initialize/listTools/callTool, so a parsing bug
# in the real client would go undetected. mcp_client's HttpClient is a
# *blocking* std/httpclient, and mock_mcp_server.nim is a single-threaded
# async server sharing this test's event loop, so the two can't be driven
# together on one thread (same issue documented in mock_llm_server.nim).
# Reuse mock_llm_server's generic thread-based raw-HTTP mock instead — MCP
# is just JSON-RPC over HTTP POST, so it doesn't need MCP-specific behavior,
# just a FIFO queue of responses on its own OS thread.
# ---------------------------------------------------------------------------

const InitSuccessBody =
  """{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"mock","version":"1.0"}}}"""

proc newInitializedClient(server: MockServer): McpClient =
  ## Enqueues a successful `initialize` handshake (2 requests: the call
  ## itself, plus the best-effort "initialized" notification it always
  ## sends afterward) and returns a client that has already completed it.
  server.enqueue("200 OK", InitSuccessBody)
  server.enqueue("200 OK", "{}")
  result = newMcpClient(newMcpServerConfig(url = baseUrlFor(server)))
  discard result.initialize()

suite "mcp_client real round-trip (thread-based mock server)":
  test "initialize performs the real handshake and parses the protocol version":
    let server = startMockServer()
    defer: stopMockServer(server)
    server.enqueue("200 OK", InitSuccessBody)
    server.enqueue("200 OK", "{}")
    let client = newMcpClient(newMcpServerConfig(url = baseUrlFor(server)))

    let version = client.initialize()

    check version == "2024-11-05"
    check client.protocolVersion == "2024-11-05"
    check server.requestCount == 2

  test "listTools parses real tool definitions returned by the server":
    let server = startMockServer()
    defer: stopMockServer(server)
    let client = newInitializedClient(server)
    server.enqueue("200 OK", """{"jsonrpc":"2.0","id":2,"result":{"tools":[
      {"name":"read_file","description":"Read a file","inputSchema":{"type":"object"}},
      {"name":"write_file","description":"Write a file","inputSchema":{"type":"object"}}
    ]}}""")

    let tools = client.listTools()

    check tools.len == 2
    check tools[0].name == "read_file"
    check tools[0].description == "Read a file"
    check tools[1].name == "write_file"

  test "callTool returns the text content the server actually sent":
    let server = startMockServer()
    defer: stopMockServer(server)
    let client = newInitializedClient(server)
    server.enqueue("200 OK",
      """{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"the answer is 42"}]}}""")

    let output = client.callTool("add", %*{"a": 1, "b": 41})

    check output == "the answer is 42"
    check "\"a\":1" in server.requestBodies[^1]
    check "\"b\":41" in server.requestBodies[^1]

  test "a JSON-RPC error response raises McpProtocolError with the server's message":
    let server = startMockServer()
    defer: stopMockServer(server)
    server.enqueue("200 OK",
      """{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}""")
    let client = newMcpClient(newMcpServerConfig(url = baseUrlFor(server)))

    var caught = false
    try:
      discard client.initialize()
    except McpProtocolError as e:
      caught = true
      check "boom" in e.msg
    check caught

# ---------------------------------------------------------------------------
# Malformed server responses — regression guards for the AssertionDefect
# class: `.hasKey` on a non-object JsonNode is a Defect (not a
# CatchableError), so before the kind guards every case below crashed the
# whole process instead of raising McpProtocolError.
# ---------------------------------------------------------------------------

import talos_core/tool_registry
import talos_core/mcp_tool

suite "mcp_client malformed responses (thread-based mock server)":
  test "non-object JSON-RPC response raises McpProtocolError, not a crash":
    let server = startMockServer()
    defer: stopMockServer(server)
    server.enqueue("200 OK", "\"oops\"")
    let client = newMcpClient(newMcpServerConfig(url = baseUrlFor(server)))
    expect McpProtocolError:
      discard client.initialize()

  test "initialize with non-object result raises McpProtocolError":
    let server = startMockServer()
    defer: stopMockServer(server)
    server.enqueue("200 OK", """{"jsonrpc":"2.0","id":1,"result":"oops"}""")
    let client = newMcpClient(newMcpServerConfig(url = baseUrlFor(server)))
    expect McpProtocolError:
      discard client.initialize()

  test "listTools with non-object result returns no tools":
    let server = startMockServer()
    defer: stopMockServer(server)
    let client = newInitializedClient(server)
    server.enqueue("200 OK", """{"jsonrpc":"2.0","id":2,"result":"oops"}""")
    check client.listTools().len == 0

  test "callTool with non-object result falls back to raw JSON":
    let server = startMockServer()
    defer: stopMockServer(server)
    let client = newInitializedClient(server)
    server.enqueue("200 OK", """{"jsonrpc":"2.0","id":3,"result":"oops"}""")
    check client.callTool("t", %*{}) == "\"oops\""

# ---------------------------------------------------------------------------
# _callerId must never reach the remote server (wire-level assertion)
# ---------------------------------------------------------------------------

suite "mcp_tool strips _callerId on the wire":
  test "registered MCP tool forwards args without _callerId":
    let server = startMockServer()
    defer: stopMockServer(server)
    let client = newInitializedClient(server)
    server.enqueue("200 OK",
      """{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"ok"}]}}""")

    let reg = newToolRegistry()
    registerMcpTool(reg,
      McpTool(server: "mock", name: "echo_tool", description: ""), client)
    let res = reg.execute("echo_tool",
      %*{"q": "hi", "_callerId": "discord-user-42"})

    check not res.isError
    let wire = server.requestBodies[^1]
    check "_callerId" notin wire
    check "discord-user-42" notin wire
    check "\"q\":\"hi\"" in wire

# ---------------------------------------------------------------------------
# SseParser — pure, no server needed
# ---------------------------------------------------------------------------

suite "SseParser":
  test "a single complete event in one chunk dispatches once":
    var p = newSseParser()
    let events = p.feed("event: message\ndata: hello\n\n")
    check events.len == 1
    check events[0].eventType == "message"
    check events[0].data == "hello"

  test "no eventType defaults to 'message'":
    var p = newSseParser()
    let events = p.feed("data: hi\n\n")
    check events.len == 1
    check events[0].eventType == "message"

  test "multi-line data is joined with newlines":
    var p = newSseParser()
    let events = p.feed("data: line1\ndata: line2\n\n")
    check events.len == 1
    check events[0].data == "line1\nline2"

  test "id field is captured":
    var p = newSseParser()
    let events = p.feed("id: 42\ndata: x\n\n")
    check events.len == 1
    check events[0].id == "42"

  test "a chunk split mid-line is buffered correctly across feed() calls":
    var p = newSseParser()
    check p.feed("data: hel").len == 0
    let events = p.feed("lo\n\n")
    check events.len == 1
    check events[0].data == "hello"

  test "a chunk split mid-event (after a complete line) is buffered correctly":
    var p = newSseParser()
    check p.feed("event: custom\n").len == 0
    check p.feed("data: partial\n").len == 0
    let events = p.feed("\n")
    check events.len == 1
    check events[0].eventType == "custom"

  test "two events in one chunk both dispatch":
    var p = newSseParser()
    let events = p.feed("data: one\n\ndata: two\n\n")
    check events.len == 2
    check events[0].data == "one"
    check events[1].data == "two"

  test "comment lines (starting with ':') are ignored":
    var p = newSseParser()
    let events = p.feed(": this is a heartbeat comment\ndata: real\n\n")
    check events.len == 1
    check events[0].data == "real"

  test "an event with no data lines at all is not dispatched":
    var p = newSseParser()
    let events = p.feed("event: ping\n\n")
    check events.len == 0

  test "\\r\\n line endings are handled":
    var p = newSseParser()
    let events = p.feed("data: crlf\r\n\r\n")
    check events.len == 1
    check events[0].data == "crlf"

  test "retry: field is ignored without affecting parsing":
    var p = newSseParser()
    let events = p.feed("retry: 3000\ndata: x\n\n")
    check events.len == 1
    check events[0].data == "x"

# ---------------------------------------------------------------------------
# McpStreamingClient — real async HTTP against the mock SSE server
# ---------------------------------------------------------------------------

suite "McpStreamingClient":
  test "listen() dispatches events served by a real HTTP response":
    let server = newMockMcpServer()
    waitFor server.start()
    defer: server.stop()
    server.addSseEvent("message", "hello world")
    server.addSseEvent("tool_list_changed", "{}")

    var received: seq[McpSseEvent] = @[]
    let client = newMcpStreamingClient(server.sseUrl(),
      onEvent = proc(e: McpSseEvent) {.gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          received.add(e))

    proc runOnce() {.async.} =
      let fut = client.listen()
      # listen() runs until the server closes the connection (a
      # non-chunked, finite mock response closes right after the body is
      # sent), so it naturally completes on its own here.
      await fut

    discard waitFor runOnce().withTimeout(5000)
    check received.len == 2
    check received[0].eventType == "message"
    check received[0].data == "hello world"
    check received[1].eventType == "tool_list_changed"

  test "lastEventId is tracked and sent as Last-Event-Id on reconnect":
    let server = newMockMcpServer()
    waitFor server.start()
    defer: server.stop()
    server.addSseEvent("message", "hi", id = "evt-7")

    let client = newMcpStreamingClient(server.sseUrl())
    discard waitFor client.listen().withTimeout(5000)
    check client.lastEventId == "evt-7"

    # A second connection should carry Last-Event-Id forward.
    discard waitFor client.listen().withTimeout(5000)
    check server.lastLastEventIdHeader == "evt-7"

  test "newMcpStreamingClient defaults timeoutMs and accepts an override":
    check newMcpStreamingClient("http://localhost:1").timeoutMs == DefaultMcpSseTimeoutMs
    check newMcpStreamingClient("http://localhost:1", timeoutMs = 500).timeoutMs == 500

  test "run() gives up after maxRetries consecutive failures against an unreachable server":
    # Port 1 is a privileged port nothing listens on in these tests — the
    # connection is refused immediately, so this stays fast without relying
    # on the timeout path.
    let client = newMcpStreamingClient("http://127.0.0.1:1/sse", timeoutMs = 200)
    let ok = waitFor client.run(reconnectDelayMs = 1, maxReconnectDelayMs = 2,
                                 maxRetries = 2).withTimeout(5000)
    check ok
    check client.running == false
