## MCP tool registration — converts `McpTool` objects into `Tool`s in a `ToolRegistry`.
##
## The key challenge: MCP tools are identified by name and take arbitrary JSON
## arguments, which maps naturally to OpenAI function-calling. This module
## bridges the two representations:
##   - `McpTool` (from mcp_client.nim) → `Tool` (from tool_registry.nim)
##   - `ToolExecuteProc` wraps `McpClient.callTool` and returns `ToolResult`
##
## The wrapper procedure is `{.gcsafe, raises: [].}` so it fits the
## `ToolExecuteProc` signature and can live inside a `ToolRegistry` without
## leaking exceptions to the agent loop.

import std/[httpclient, json]

import talos_core/config
import talos_core/mcp_client
import talos_core/tool_registry

# ---------------------------------------------------------------------------
# Internal helper
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Per-tool execute proc factory
# ---------------------------------------------------------------------------

proc stripReservedArgs*(args: JsonNode): JsonNode =
  ## Returns `args` without the reserved `_callerId` key the agent loop
  ## injects into every tool call for local permission checks. Reserved
  ## keys must never reach a remote MCP server: they can fail strict
  ## schema validation, they leak the caller's identity (e.g. a real
  ## Discord user id) to a third party, and echo-style tools reflect them
  ## back into the LLM context. Returns the input unchanged (same ref)
  ## when there is nothing to strip; never mutates the input.
  if args.isNil or args.kind != JObject or not args.hasKey("_callerId"):
    return args
  result = args.copy()
  result.delete("_callerId")

proc makeMcpToolExecuteProc(
    client: McpClient;
    toolName: string;
): ToolExecuteProc =
  ## Builds a `ToolExecuteProc` closure that calls `toolName` on the given
  ## MCP client. The closure captures the client and tool name so each
  ## registered MCP tool has its own isolated execution path.
  let name = toolName  # capture into closure
  let mc = client       # capture ref safely
  result = proc (args: JsonNode): ToolResult {.gcsafe, raises: [].} =
    try:
      let output = mc.callTool(name, stripReservedArgs(args))
      ToolResult(output: output, isError: false, exitCode: 0)
    except McpToolNotFoundError as e:
      ToolResult(output: "tool not found on MCP server: " & e.msg,
                isError: true, exitCode: -1)
    except McpError as e:
      ToolResult(output: "MCP error: " & e.msg, isError: true, exitCode: -1)
    except CatchableError as e:
      ToolResult(output: "unexpected error calling MCP tool: " & e.msg,
                isError: true, exitCode: -1)
    except Exception as e:
      # catch-all for {.raises: [].} — wraps any remaining exceptions
      # (including bare Exception) into tool errors.
      ToolResult(output: "internal error calling MCP tool: " & e.msg,
                isError: true, exitCode: -1)
    except Defect as e:
      # Required for {.raises: [].} — wraps fatal defects into tool errors
      # so the agent loop doesn't crash. Matches shell tool pattern.
      ToolResult(output: "internal error calling MCP tool: " & e.msg,
                isError: true, exitCode: -1)

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

proc registerMcpTool*(
    reg: ToolRegistry;
    mcpTool: McpTool;
    client: McpClient;
) =
  ## Registers a single `McpTool` into a `ToolRegistry` using the provided
  ## `McpClient` for execution. The tool's name is used as-is (no prefix).
  ##
  ## Raises `ToolDuplicateError` if a tool with the same name is already
  ## registered. Raises `ToolArgumentError` if `mcpTool.name` is empty.
  if mcpTool.name.len == 0:
    raise newException(ToolArgumentError, "MCP tool name must be non-empty")

  let executeProc = makeMcpToolExecuteProc(client, mcpTool.name)
  let parameters = if mcpTool.inputSchema.isNil:
    newJObject()
  else:
    mcpTool.inputSchema

  reg.register(
    name = mcpTool.name,
    description = mcpTool.description,
    parameters = parameters,
    execute = executeProc,
  )

proc registerMcpTools*(
    reg: ToolRegistry;
    mcpTools: seq[McpTool];
    client: McpClient;
    registered: var seq[McpTool];
) =
  ## Registers all `McpTool` objects into a `ToolRegistry`. Uses the same
  ## `McpClient` for all tools (assumes they come from the same server).
  ## Appends each tool to `registered` as it lands in the registry.
  ##
  ## Raises `ToolDuplicateError` on the first name collision with an
  ## already-registered tool. `registered` is a `var` out-parameter (not a
  ## return value) precisely so partial progress survives that raise: a
  ## `result =` assignment in the caller never executes when the callee
  ## raises, which is how a previous version of registerMcpServer ended up
  ## closing a client that live tools still referenced.
  for tool in mcpTools:
    if reg.has(tool.name):
      raise newException(ToolDuplicateError,
        "tool '" & tool.name & "' already registered; cannot add from MCP")
    registerMcpTool(reg, tool, client)
    registered.add(tool)

proc registerMcpTools*(
    reg: ToolRegistry;
    mcpTools: seq[McpTool];
    client: McpClient;
): seq[McpTool] {.discardable.} =
  ## Convenience overload returning the registered subset. Only safe when
  ## the caller doesn't need partial progress after an exception.
  result = @[]
  registerMcpTools(reg, mcpTools, client, result)

# ---------------------------------------------------------------------------
# Convenience: build and register from server configs in one shot
# ---------------------------------------------------------------------------

proc registerMcpServer*(
    reg: ToolRegistry;
    serverCfg: McpServerConfig;
): seq[McpTool] =
  ## Connects to one MCP server, discovers its tools, and registers them
  ## all into `reg`. Returns the list of tools that were registered.
  ## If the server is disabled or unreachable, returns an empty sequence
  ## (no exception raised — caller decides logging/handling).
  result = @[]
  if not serverCfg.enabled:
    return

  var client = newMcpClient(serverCfg)
  try:
    discard client.initialize()
    let tools = client.listTools()
    # `result` is passed as the var out-parameter so it reflects tools
    # actually registered even when registerMcpTools raises partway (e.g. a
    # name collision after tool 2 of 5): the `result.len == 0` check below
    # then correctly detects "nothing holds a reference to this client".
    registerMcpTools(reg, tools, client, result)
    # Keep client alive — its HttpClient is used by each tool's execute proc.
  except CatchableError as e:
    if result.len == 0:
      client.http.close()
    stderr.writeLine("Warning: MCP server '" & serverCfg.url &
                     "' registration failed: " & e.msg)

proc registerMcpServers*(
    reg: ToolRegistry;
    serverCfgs: seq[McpServerConfig];
): int =
  ## Calls `registerMcpServer` for each server config and returns the total
  ## number of tools registered across all servers.
  result = 0
  for cfg in serverCfgs:
    let tools = registerMcpServer(reg, cfg)
    result += tools.len