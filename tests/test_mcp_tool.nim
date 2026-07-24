## Tests for talos_core/mcp_tool.nim

import std/[unittest, json, strutils]
import talos_core/config
import talos_core/mcp_client
import talos_core/mcp_tool
import talos_core/tool_registry

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
