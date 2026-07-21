## Tests for talos_core/tool_registry.
##
## Shell-tool-specific tests (execution, timeout, deny-list) live in
## talos_agent/tests/test_shell_tool.nim to avoid a cross-package
## dependency on talos_agent/tools/shell.

import std/[json, strutils, unittest]

import talos_core/tool_registry

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc echoTool(): Tool =
  ## A trivial tool used to exercise registry plumbing.
  let params = %*{
    "type": "object",
    "properties": {
      "msg": {"type": "string"}
    },
    "required": ["msg"],
  }
  newTool(
    name = "echo",
    description = "Echo a message back",
    parameters = params,
    execute = proc (args: JsonNode): ToolResult {.gcsafe, raises: [].} =
      let msgNode = args{"msg"}
      if msgNode.isNil or msgNode.kind != JString:
        return ToolResult(output: "missing msg", isError: true, exitCode: -1)
      ToolResult(output: msgNode.getStr(), isError: false, exitCode: 0)
  )

# ---------------------------------------------------------------------------
# Registry basics
# ---------------------------------------------------------------------------

suite "ToolRegistry basics":
  test "newToolRegistry is empty":
    let reg = newToolRegistry()
    check reg.len == 0
    check reg.list().len == 0
    check reg.names().len == 0

  test "register and retrieve":
    let reg = newToolRegistry()
    reg.register(echoTool())
    check reg.len == 1
    check reg.has("echo")
    let t = reg.get("echo")
    check t.name == "echo"
    check t.description.contains("Echo")

  test "duplicate registration raises":
    let reg = newToolRegistry()
    reg.register(echoTool())
    expect ToolDuplicateError:
      reg.register(echoTool())

  test "missing tool raises ToolNotFoundError":
    let reg = newToolRegistry()
    expect ToolNotFoundError:
      discard reg.get("nope")

  test "unregister removes tool":
    let reg = newToolRegistry()
    reg.register(echoTool())
    check reg.unregister("echo")
    check reg.len == 0
    check (not reg.has("echo"))
    check (not reg.unregister("echo"))

  test "list preserves insertion order":
    let reg = newToolRegistry()
    reg.register(newTool("a", "A", emptyParameters(),
      proc (a: JsonNode): ToolResult {.gcsafe, raises: [].} =
        ToolResult(output: "a", isError: false, exitCode: 0)))
    reg.register(newTool("b", "B", emptyParameters(),
      proc (a: JsonNode): ToolResult {.gcsafe, raises: [].} =
        ToolResult(output: "b", isError: false, exitCode: 0)))
    reg.register(newTool("c", "C", emptyParameters(),
      proc (a: JsonNode): ToolResult {.gcsafe, raises: [].} =
        ToolResult(output: "c", isError: false, exitCode: 0)))
    check reg.names() == @["a", "b", "c"]

  test "newTool rejects empty name":
    expect ToolArgumentError:
      discard newTool("", "x", emptyParameters(),
        proc (a: JsonNode): ToolResult {.gcsafe, raises: [].} =
          ToolResult(output: "", isError: false, exitCode: 0))

  test "newTool rejects nil execute":
    expect ToolArgumentError:
      discard newTool("x", "x", emptyParameters(), nil)

# ---------------------------------------------------------------------------
# OpenAI-compatible serialization
# ---------------------------------------------------------------------------

suite "ToolRegistry OpenAI definitions":
  test "single tool has correct shape":
    let t = echoTool()
    let def = toOpenAIDefinition(t)
    check def["type"].getStr() == "function"
    check def["function"]["name"].getStr() == "echo"
    check def["function"]["description"].getStr() == "Echo a message back"
    check def["function"]["parameters"]["type"].getStr() == "object"
    check def["function"]["parameters"]["properties"].hasKey("msg")
    check def["function"]["parameters"]["required"][0].getStr() == "msg"

  test "registry serialization is an array of definitions":
    let reg = newToolRegistry()
    reg.register(echoTool())
    let arr = reg.toOpenAIDefinitions()
    check arr.kind == JArray
    check arr.len == 1
    check arr[0]["function"]["name"].getStr() == "echo"
    for entry in arr:
      check entry["type"].getStr() == "function"
      check entry["function"]["parameters"]["type"].getStr() == "object"

  test "definitions are independent copies":
    let reg = newToolRegistry()
    reg.register(echoTool())
    let arr1 = reg.toOpenAIDefinitions()
    arr1[0]["function"]["name"] = %"hijacked"
    # Registry state must remain unchanged.
    let arr2 = reg.toOpenAIDefinitions()
    check arr2[0]["function"]["name"].getStr() == "echo"

# ---------------------------------------------------------------------------
# Argument parsing & execution surface
# ---------------------------------------------------------------------------

suite "ToolRegistry argument parsing":
  test "empty string parses to empty object":
    let n = parseArguments("")
    check n.kind == JObject
    check n.len == 0

  test "valid JSON object parses":
    let n = parseArguments("""{"a": 1, "b": "x"}""")
    check n["a"].getInt() == 1
    check n["b"].getStr() == "x"

  test "invalid JSON raises ToolArgumentError":
    expect ToolArgumentError:
      discard parseArguments("not json")

  test "non-object root raises ToolArgumentError":
    expect ToolArgumentError:
      discard parseArguments("[1,2,3]")

suite "ToolRegistry execute":
  test "executes a registered tool with parsed JSON":
    let reg = newToolRegistry()
    reg.register(echoTool())
    let res = reg.execute("echo", """{"msg": "hi"}""")
    check (not res.isError)
    check res.output == "hi"

  test "execute on missing tool raises":
    let reg = newToolRegistry()
    expect ToolNotFoundError:
      discard reg.execute("nope", "{}")

  test "execute returns isError on bad JSON arguments":
    let reg = newToolRegistry()
    reg.register(echoTool())
    let res = reg.execute("echo", "not json")
    check res.isError
    check res.output.contains("invalid arguments")

  test "execute returns isError on non-object args":
    let reg = newToolRegistry()
    reg.register(echoTool())
    let res = reg.execute("echo", "[]")
    check res.isError
