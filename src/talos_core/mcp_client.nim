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

import std/[httpclient, json, times, strutils, os]

import talos_core/config

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

proc parseHttpStatusCode(status: string): int =
  let s = status.strip()
  let spaceIdx = s.find(' ')
  let codePart = if spaceIdx >= 0: s[0 ..< spaceIdx] else: s
  try:
    return parseInt(codePart)
  except ValueError:
    return 0

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
  if node.hasKey("id"):
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

  let statusCode = parseHttpStatusCode(response.status)
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

  # Check for JSON-RPC error response.
  if respNode.kind == JObject and respNode.hasKey("error"):
    let errMsg = if respNode["error"].hasKey("message"):
      respNode["error"]["message"].getStr()
    else:
      "unknown JSON-RPC error"
    let errCode = if respNode["error"].hasKey("code"):
      respNode["error"]["code"].getInt()
    else:
      -1
    var err = newException(McpProtocolError,
      "MCP server '" & client.cfg.url &
      "' returned JSON-RPC error [" & $errCode & "]: " & errMsg)
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
  if resultNode.hasKey("tools") and resultNode["tools"].kind == JArray:
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
  if resultNode.hasKey("content") and resultNode["content"].kind == JArray:
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