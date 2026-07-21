## Talos tool registry.
##
## Provides a registry for callable tools that an LLM can invoke via
## OpenAI-style tool/function calling. Each tool exposes:
##   - a name (unique within the registry),
##   - a human-readable description,
##   - a JSON-schema describing its parameters (OpenAI / JSON Schema draft),
##   - an `execute` proc that takes a JSON arguments object and returns a
##     `ToolResult` containing output text plus an optional error/exit code.
##
## The registry can serialize all registered tools into the JSON array shape
## that goes into the `tools` field of an OpenAI-compatible chat completion
## request:
##   [{"type": "function",
##     "function": {"name": ..., "description": ..., "parameters": {...}}}, ...]
##
## Out of scope (deferred):
##   - File/network/MCP tools (Phase 2)
##   - Cascading permissions / per-call approval
##   - Streaming tool output

import std/[json, tables, strutils]

type
  ToolError* = object of CatchableError
    ## Base type for tool-level errors.

  ToolNotFoundError* = object of ToolError
    ## Raised when looking up an unregistered tool.

  ToolDuplicateError* = object of ToolError
    ## Raised when registering a tool whose name already exists.

  ToolArgumentError* = object of ToolError
    ## Raised when a tool's arguments are malformed.

  ToolExecutionError* = object of ToolError
    ## Raised when a tool fails to execute internally (the registry wraps
    ## unexpected exceptions in this type so callers see a uniform surface).

  ToolResult* = object
    ## The result of executing a tool.
    ##
    ## `output` is the user/LLM-visible stringified result (typically stdout
    ## or a textual summary). `isError` indicates whether the tool itself
    ## reported a failure (e.g. non-zero exit code, denied command). When
    ## `isError` is true, `output` should explain the failure. `exitCode`
    ## is optional and most relevant for process-style tools (0 on success,
    ## any other value on failure).
    output*: string
    isError*: bool
    exitCode*: int

  ToolExecuteProc* = proc (args: JsonNode): ToolResult {.gcsafe.}
    ## Executes a tool with the given JSON arguments. SHOULD NOT raise; any
    ## error condition should be returned as a ToolResult with isError=true.
    ## The `{.gcsafe.}` pragma is required for safe capture in closures.

  Tool* = object
    ## A single callable tool exposed to the LLM.
    name*: string                     ## Unique name (e.g. "shell").
    description*: string              ## Short human/LLM-readable description.
    parameters*: JsonNode             ## JSON Schema for arguments.
    execute*: proc (args: JsonNode): ToolResult

  ToolRegistry* = ref object
    ## A collection of named tools.
    tools: OrderedTable[string, Tool]

# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------

proc newToolRegistry*(): ToolRegistry =
  ## Creates a new, empty tool registry.
  ToolRegistry(tools: initOrderedTable[string, Tool]())

proc emptyParameters*(): JsonNode =
  ## Returns a JSON Schema for a tool that takes no arguments.
  ## Equivalent to `{"type": "object", "properties": {}}`.
  result = newJObject()
  result["type"] = %"object"
  result["properties"] = newJObject()

proc newTool*(
    name, description: string;
    parameters: JsonNode;
    execute: proc (args: JsonNode): ToolResult;
): Tool =
  ## Builds a `Tool` value. `parameters` should be a JSON Schema object
  ## (typically `{"type": "object", "properties": {...}, "required": [...]}`).
  if name.len == 0:
    raise newException(ToolArgumentError, "tool name must be non-empty")
  if execute.isNil:
    raise newException(ToolArgumentError, "tool execute proc must not be nil")
  let params = if parameters.isNil: emptyParameters() else: parameters
  Tool(
    name: name,
    description: description,
    parameters: params,
    execute: execute,
  )

# ---------------------------------------------------------------------------
# Registry operations
# ---------------------------------------------------------------------------

proc register*(reg: ToolRegistry; tool: Tool) =
  ## Registers a tool. Raises `ToolDuplicateError` if a tool with the same
  ## name is already registered.
  if tool.name.len == 0:
    raise newException(ToolArgumentError, "tool name must be non-empty")
  if reg.tools.hasKey(tool.name):
    raise newException(ToolDuplicateError,
      "tool '" & tool.name & "' is already registered")
  reg.tools[tool.name] = tool

proc register*(
    reg: ToolRegistry;
    name, description: string;
    parameters: JsonNode;
    execute: proc (args: JsonNode): ToolResult;
) =
  ## Convenience overload: builds a Tool and registers it in one step.
  reg.register(newTool(name, description, parameters, execute))

proc unregister*(reg: ToolRegistry; name: string): bool {.discardable.} =
  ## Removes a tool from the registry. Returns true if a tool was removed.
  if reg.tools.hasKey(name):
    reg.tools.del(name)
    return true
  return false

proc has*(reg: ToolRegistry; name: string): bool =
  ## Returns true if a tool with the given name is registered.
  reg.tools.hasKey(name)

proc get*(reg: ToolRegistry; name: string): Tool =
  ## Retrieves a registered tool by name. Raises `ToolNotFoundError` if
  ## the tool is not registered.
  if not reg.tools.hasKey(name):
    raise newException(ToolNotFoundError,
      "tool '" & name & "' is not registered")
  reg.tools[name]

proc list*(reg: ToolRegistry): seq[Tool] =
  ## Returns all registered tools in insertion order.
  result = @[]
  for _, tool in reg.tools:
    result.add(tool)

proc names*(reg: ToolRegistry): seq[string] =
  ## Returns the names of all registered tools in insertion order.
  result = @[]
  for name in reg.tools.keys:
    result.add(name)

proc len*(reg: ToolRegistry): int =
  ## Returns the number of registered tools.
  reg.tools.len

# ---------------------------------------------------------------------------
# OpenAI-compatible serialization
# ---------------------------------------------------------------------------

proc toOpenAIDefinition*(tool: Tool): JsonNode =
  ## Returns a single tool's OpenAI-style definition:
  ##   {"type": "function",
  ##    "function": {"name": ..., "description": ..., "parameters": {...}}}
  var fn = newJObject()
  fn["name"] = %tool.name
  fn["description"] = %tool.description
  # Copy parameters defensively so callers can't mutate the registry state.
  fn["parameters"] = tool.parameters.copy()
  result = newJObject()
  result["type"] = %"function"
  result["function"] = fn

proc toOpenAIDefinitions*(reg: ToolRegistry): JsonNode =
  ## Serializes all registered tools as a JSON array suitable for the
  ## `tools` field of an OpenAI Chat Completions request.
  result = newJArray()
  for _, tool in reg.tools:
    result.add(toOpenAIDefinition(tool))

# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

proc parseArguments*(arguments: string): JsonNode =
  ## Parses a JSON-encoded arguments string (as produced by an LLM tool call)
  ## into a JsonNode. Empty strings produce an empty object. Raises
  ## `ToolArgumentError` on invalid JSON or non-object roots.
  let trimmed = arguments.strip()
  if trimmed.len == 0:
    return newJObject()
  var node: JsonNode
  try:
    node = parseJson(trimmed)
  except JsonParsingError as e:
    raise newException(ToolArgumentError,
      "tool arguments must be valid JSON: " & e.msg)
  except CatchableError as e:
    raise newException(ToolArgumentError,
      "failed to parse tool arguments: " & e.msg)
  if node.kind != JObject:
    raise newException(ToolArgumentError,
      "tool arguments must be a JSON object, got: " & $node.kind)
  node

proc execute*(reg: ToolRegistry; name: string; args: JsonNode): ToolResult =
  ## Executes the named tool with parsed JSON arguments. Translates internal
  ## exceptions into a `ToolResult` with `isError=true`. Raises
  ## `ToolNotFoundError` if the tool is not registered (this is a programmer
  ## error, distinct from a tool-reported failure).
  let tool = reg.get(name)
  let argsNode = if args.isNil: newJObject() else: args
  try:
    return tool.execute(argsNode)
  except CatchableError as e:
    return ToolResult(
      output: "tool '" & name & "' raised: " & e.msg,
      isError: true,
      exitCode: -1,
    )

proc execute*(reg: ToolRegistry; name, arguments: string): ToolResult =
  ## Executes the named tool, parsing `arguments` as JSON. If the arguments
  ## are malformed, returns a `ToolResult` with `isError=true` rather than
  ## raising; this matches how an LLM-generated tool call should be handled
  ## inside an agent loop.
  if not reg.has(name):
    raise newException(ToolNotFoundError,
      "tool '" & name & "' is not registered")
  var argsNode: JsonNode
  try:
    argsNode = parseArguments(arguments)
  except ToolArgumentError as e:
    return ToolResult(
      output: "invalid arguments for tool '" & name & "': " & e.msg,
      isError: true,
      exitCode: -1,
    )
  reg.execute(name, argsNode)
