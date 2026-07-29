## Tests for talos_core/mcp_tool.nim

import std/[unittest, json, strutils]
import talos_core/config
import talos_core/mcp_client
import talos_core/mcp_tool
import talos_core/tool_registry
import talos_core/testkit/mock_llm_server

# refreshMcpServerTools/registerMcpServerSse below need a *synchronous*
# McpClient round-trip. mcp_tool.nim's mock (mock_mcp_server.nim) is a
# single-threaded async server sharing this test's event loop, which
# deadlocks against a blocking client on the same thread (see the comment
# in test_mcp_client.nim). mock_llm_server's generic thread-based mock
# doesn't have that problem — MCP is just JSON-RPC over HTTP POST, so a
# path/method-agnostic FIFO responder works fine for these.

const InitSuccessBody =
  """{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"mock","version":"1.0"}}}"""

proc newInitializedClient(server: MockServer): McpClient =
  server.enqueue("200 OK", InitSuccessBody)
  server.enqueue("200 OK", "{}")
  result = newMcpClient(newMcpServerConfig(url = baseUrlFor(server)))
  discard result.initialize()

# ---------------------------------------------------------------------------
# Tests: registerMcpTool
# ---------------------------------------------------------------------------

suite "registerMcpTool":
  test "registers a single MCP tool":
    let reg = newToolRegistry()
    let cfg = newMcpServerConfig(url = "http://localhost:19999/mcp")
    var client = newMcpClient(cfg)

    let mcpTool = McpTool(
      server: "test",
      name: "my_tool",
      description: "A test tool",
      inputSchema: %*{"type": "object", "properties": {"arg": {"type": "string"}}},
    )
    registerMcpTool(reg, mcpTool, client)

    check reg.has("my_tool")
    let tool = reg.get("my_tool")
    check tool.name == "my_tool"
    check tool.description == "A test tool"
    check tool.parameters["type"].getStr() == "object"

  test "raises ToolArgumentError on empty name":
    let reg = newToolRegistry()
    let cfg = newMcpServerConfig()
    var client = newMcpClient(cfg)

    let mcpTool = McpTool(
      server: "test",
      name: "",
      description: "no name tool",
    )
    expect ToolArgumentError:
      registerMcpTool(reg, mcpTool, client)

  test "raises ToolDuplicateError on duplicate name":
    let reg = newToolRegistry()
    let cfg = newMcpServerConfig()
    var client = newMcpClient(cfg)

    let mcpTool = McpTool(
      server: "test",
      name: "dup_tool",
      description: "first",
    )
    registerMcpTool(reg, mcpTool, client)

    let dupTool = McpTool(
      server: "test",
      name: "dup_tool",
      description: "second (duplicate)",
    )
    expect ToolDuplicateError:
      registerMcpTool(reg, dupTool, client)

  test "stores null inputSchema as empty object":
    let reg = newToolRegistry()
    let cfg = newMcpServerConfig()
    var client = newMcpClient(cfg)

    let mcpTool = McpTool(
      server: "test",
      name: "null_schema",
      description: "no schema",
      inputSchema: nil,
    )
    registerMcpTool(reg, mcpTool, client)
    let tool = reg.get("null_schema")
    check tool.parameters.kind == JObject
    check tool.parameters.len == 0

# ---------------------------------------------------------------------------
# Tests: stripReservedArgs
# ---------------------------------------------------------------------------

suite "stripReservedArgs":
  test "_callerId is removed, other args untouched":
    let args = %*{"query": "weather", "_callerId": "discord-user-42", "n": 3}
    let cleaned = stripReservedArgs(args)
    check not cleaned.hasKey("_callerId")
    check cleaned["query"].getStr() == "weather"
    check cleaned["n"].getInt() == 3

  test "input is not mutated":
    # The same args node is reused for local logging/memory after the MCP
    # call; stripping must operate on a copy.
    let args = %*{"query": "weather", "_callerId": "discord-user-42"}
    discard stripReservedArgs(args)
    check args.hasKey("_callerId")

  test "args without _callerId pass through unchanged":
    let args = %*{"query": "weather"}
    check stripReservedArgs(args) == args

  test "nil and non-object args pass through":
    check stripReservedArgs(nil).isNil
    let arr = %*[1, 2, 3]
    check stripReservedArgs(arr) == arr

# ---------------------------------------------------------------------------
# Tests: registerMcpTools
# ---------------------------------------------------------------------------

suite "registerMcpTools":
  test "registers multiple tools":
    let reg = newToolRegistry()
    let cfg = newMcpServerConfig()
    var client = newMcpClient(cfg)

    let tools = @[
      McpTool(server: "srv", name: "tool_a", description: "First tool"),
      McpTool(server: "srv", name: "tool_b", description: "Second tool",
              inputSchema: %*{"type": "object"}),
    ]
    registerMcpTools(reg, tools, client)

    check reg.has("tool_a")
    check reg.has("tool_b")
    check reg.get("tool_a").description == "First tool"

  test "raises ToolDuplicateError on collision":
    let reg = newToolRegistry()
    let cfg = newMcpServerConfig()
    var client = newMcpClient(cfg)

    let first = McpTool(server: "srv", name: "collide", description: "first")
    registerMcpTool(reg, first, client)

    let second = McpTool(server: "srv", name: "collide", description: "second")
    let third = McpTool(server: "srv", name: "other", description: "fine")
    expect ToolDuplicateError:
      registerMcpTools(reg, @[second, third], client)

    # Third tool should NOT have been registered (error on first collision)
    check not reg.has("other")

  test "var out-param reflects partial progress after a raise":
    # Regression guard for the client-leak fix: registerMcpServer decides
    # whether to close the shared HttpClient based on how many tools were
    # actually registered before the failure. A `result =` assignment in
    # the caller never executes when the callee raises, so this progress
    # has to travel through the var out-parameter instead.
    let reg = newToolRegistry()
    let cfg = newMcpServerConfig(url = "http://localhost:19996/mcp", timeoutMs = 500)
    var client = newMcpClient(cfg)

    registerMcpTool(reg,
      McpTool(server: "srv", name: "taken", description: "pre-existing"),
      client)

    let batch = @[
      McpTool(server: "srv", name: "fresh_a", description: "lands"),
      McpTool(server: "srv", name: "fresh_b", description: "lands"),
      McpTool(server: "srv", name: "taken", description: "collides"),
      McpTool(server: "srv", name: "never", description: "unreached"),
    ]
    var registered: seq[McpTool] = @[]
    expect ToolDuplicateError:
      registerMcpTools(reg, batch, client, registered)

    # The two tools registered before the collision survived the raise —
    # both in the registry and, critically, in the out-param the caller
    # uses for its close-the-client decision.
    check registered.len == 2
    check registered[0].name == "fresh_a"
    check registered[1].name == "fresh_b"
    check reg.has("fresh_a")
    check reg.has("fresh_b")
    check not reg.has("never")

    # And the registered tools' client must still be usable (not closed):
    # executing one hits an unreachable server, which is a connection
    # error ToolResult — not a crash on a closed client handle.
    let res = reg.execute("fresh_a", %*{})
    check res.isError
    check res.output.contains("connect")

# ---------------------------------------------------------------------------
# Tests: registerMcpServer (no-HTTP logic only)
# ---------------------------------------------------------------------------

suite "registerMcpServer":
  test "returns empty list for disabled server":
    let cfg = newMcpServerConfig(url = "http://localhost:19999/mcp", enabled = false)
    let reg = newToolRegistry()
    let tools = registerMcpServer(reg, cfg)
    check tools.len == 0

  test "returns empty list for unreachable server gracefully":
    let reg = newToolRegistry()
    let cfg = newMcpServerConfig(url = "http://localhost:19997/mcp", timeoutMs = 500)
    let tools = registerMcpServer(reg, cfg)
    check tools.len == 0

# ---------------------------------------------------------------------------
# Tests: registerMcpServers (no-HTTP logic only)
# ---------------------------------------------------------------------------

suite "registerMcpServers":
  test "skips disabled servers":
    let cfg = newMcpServerConfig(url = "http://localhost:19999/mcp", enabled = false)
    let reg = newToolRegistry()
    let count = registerMcpServers(reg, @[cfg])
    check count == 0

# ---------------------------------------------------------------------------
# Tests: error mapping (callMcpToolRaw is internal but tested via the
# registered execute proc against known error conditions)
#
# The execute proc captures the McpClient ref and calls callTool on it.
# When the server is unreachable, callTool raises McpConnectionError,
# which gets caught and converted to a ToolResult with isError=true.
# ---------------------------------------------------------------------------

suite "mcp_tool execute proc error handling":
  test "unreachable server returns ToolResult with error":
    let cfg = newMcpServerConfig(url = "http://localhost:19998/mcp", timeoutMs = 500)
    var client = newMcpClient(cfg)
    let reg = newToolRegistry()

    let mcpTool = McpTool(server: "test", name: "unreachable", description: "")
    registerMcpTool(reg, mcpTool, client)

    let result = reg.execute("unreachable", %*{})
    check result.isError
    check result.output.contains("failed to connect")

# ---------------------------------------------------------------------------
# Tests: refreshMcpServerTools (tool_list_changed reconciliation)
# ---------------------------------------------------------------------------

suite "refreshMcpServerTools":
  test "adds newly-listed tools and registers them":
    let server = startMockServer()
    defer: stopMockServer(server)
    let client = newInitializedClient(server)
    let reg = newToolRegistry()
    var registered: seq[McpTool] = @[]

    server.enqueue("200 OK", """{"jsonrpc":"2.0","id":2,"result":{"tools":[
      {"name":"tool_a","description":"first tool","inputSchema":{"type":"object"}}
    ]}}""")
    refreshMcpServerTools(reg, client, registered)
    check reg.has("tool_a")
    check registered.len == 1

  test "removes tools that disappeared from the server's list":
    let server = startMockServer()
    defer: stopMockServer(server)
    let client = newInitializedClient(server)
    let reg = newToolRegistry()
    var registered: seq[McpTool] = @[]

    server.enqueue("200 OK", """{"jsonrpc":"2.0","id":2,"result":{"tools":[
      {"name":"tool_a","description":"first","inputSchema":{"type":"object"}}
    ]}}""")
    refreshMcpServerTools(reg, client, registered)
    check reg.has("tool_a")

    server.enqueue("200 OK", """{"jsonrpc":"2.0","id":3,"result":{"tools":[
      {"name":"tool_b","description":"second","inputSchema":{"type":"object"}}
    ]}}""")
    refreshMcpServerTools(reg, client, registered)
    check not reg.has("tool_a")
    check reg.has("tool_b")
    check registered.len == 1
    check registered[0].name == "tool_b"

  test "an unreachable server leaves the registry untouched":
    let cfg = newMcpServerConfig(url = "http://localhost:19996/mcp", timeoutMs = 300)
    var client = newMcpClient(cfg)
    let reg = newToolRegistry()
    reg.register(name = "existing", description = "", parameters = emptyParameters(),
      execute = proc(args: JsonNode): ToolResult {.gcsafe.} = ToolResult(output: "ok"))
    var registered = @[McpTool(server: "x", name: "existing", description: "")]
    refreshMcpServerTools(reg, client, registered)
    check reg.has("existing")
    check registered.len == 1

# ---------------------------------------------------------------------------
# Tests: registerMcpServerSse / unregisterMcpServerSse
#
# These only exercise registerMcpServerSse's *synchronous* handshake path
# (same mock/reasoning as refreshMcpServerTools above) — the live
# tool_list_changed reaction is covered at the unit level by
# refreshMcpServerTools (reconciliation logic) and by test_mcp_client.nim's
# SseParser/McpStreamingClient suites (event parsing + dispatch +
# reconnect), and end-to-end by the real MCP server integration test.
# ---------------------------------------------------------------------------

suite "registerMcpServerSse":
  test "returns nil for a disabled server":
    let cfg = newMcpServerConfig(url = "http://localhost:19995/mcp", enabled = false)
    let reg = newToolRegistry()
    let handle = registerMcpServerSse(reg, cfg)
    check handle.isNil

  test "returns nil and logs a warning for an unreachable server":
    let cfg = newMcpServerConfig(url = "http://localhost:19994/mcp", timeoutMs = 300)
    let reg = newToolRegistry()
    let handle = registerMcpServerSse(reg, cfg)
    check handle.isNil

  test "registers initial tools from a real handshake and returns a live handle":
    let server = startMockServer()
    defer: stopMockServer(server)
    server.enqueue("200 OK", InitSuccessBody)
    server.enqueue("200 OK", "{}")
    server.enqueue("200 OK", """{"jsonrpc":"2.0","id":2,"result":{"tools":[
      {"name":"tool_a","description":"first tool","inputSchema":{"type":"object"}}
    ]}}""")
    let cfg = newMcpServerConfig(url = baseUrlFor(server))
    let reg = newToolRegistry()

    let handle = registerMcpServerSse(reg, cfg)
    check not handle.isNil
    check reg.has("tool_a")
    check handle.registered.len == 1

    unregisterMcpServerSse(reg, handle)
    check not reg.has("tool_a")

  test "unregisterMcpServerSse on a nil handle is a no-op, not a crash":
    let reg = newToolRegistry()
    unregisterMcpServerSse(reg, nil)

suite "registerMcpServersWithHandles":
  test "http-transport servers behave like registerMcpServer (backward compat)":
    let server = startMockServer()
    defer: stopMockServer(server)
    server.enqueue("200 OK", InitSuccessBody)
    server.enqueue("200 OK", "{}")
    server.enqueue("200 OK", """{"jsonrpc":"2.0","id":2,"result":{"tools":[
      {"name":"http_tool","description":"an http-transport tool","inputSchema":{"type":"object"}}
    ]}}""")
    let cfg = newMcpServerConfig(url = baseUrlFor(server))
    let reg = newToolRegistry()

    let res = registerMcpServersWithHandles(reg, @[cfg])
    check res.toolCount == 1
    check res.sseHandles.len == 0
    check reg.has("http_tool")

  test "sse-transport servers are registered and their handle is returned":
    let server = startMockServer()
    defer: stopMockServer(server)
    server.enqueue("200 OK", InitSuccessBody)
    server.enqueue("200 OK", "{}")
    server.enqueue("200 OK", """{"jsonrpc":"2.0","id":2,"result":{"tools":[
      {"name":"sse_tool","description":"an sse-transport tool","inputSchema":{"type":"object"}}
    ]}}""")
    var cfg = newMcpServerConfig(url = baseUrlFor(server))
    cfg.transport = "sse"
    let reg = newToolRegistry()

    let res = registerMcpServersWithHandles(reg, @[cfg])
    check res.toolCount == 1
    check res.sseHandles.len == 1
    check reg.has("sse_tool")
    unregisterMcpServerSse(reg, res.sseHandles[0])
