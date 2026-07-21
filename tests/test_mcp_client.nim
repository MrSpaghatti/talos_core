## Tests for talos_core/mcp_client.nim

import std/[unittest, json, asyncdispatch, httpclient, strutils]
import talos_core/mcp_client
import talos_core/config
import mock_mcp_server
import mock_llm_server

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
