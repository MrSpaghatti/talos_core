## Tests for talos_core/plan_executor.nim
##
## Comprehensive test suite covering:
## - parsePlan: JSON parsing and validation
## - topoSort: topological sort with cycle detection
## - generatePlan: LLM-based plan generation
## - executePlan: plan execution with tool calls and reasoning steps
## - formatPlan, formatStepStatus, formatPlanResult: display formatting

import std/[json, unittest, strutils, tables]
import talos_core/llm_client
import talos_core/plan_executor
import talos_core/tool_registry
import talos_core/memory
import talos_core/agent_loop
import talos_core/testkit/mock_llm_server

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeMemory(): Memory =
  newMemory(":memory:")

proc makeEchoTool(): Tool =
  ## A simple echo tool for testing plan execution.
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
        return ToolResult(output: "error: missing msg", isError: true, exitCode: 1)
      ToolResult(output: "ECHO: " & msgNode.getStr(), isError: false, exitCode: 0)
  )

proc makeRegistry(): ToolRegistry =
  let reg = newToolRegistry()
  reg.register(makeEchoTool())
  reg

proc validPlanJson(): string =
  """
  {
    "goal": "Test goal",
    "steps": [
      {
        "id": "1",
        "description": "First step",
        "toolName": "echo",
        "toolArgs": "{\"msg\": \"hello\"}",
        "dependsOn": []
      },
      {
        "id": "2",
        "description": "Second step",
        "toolName": "echo",
        "toolArgs": "{\"msg\": \"world\"}",
        "dependsOn": ["1"]
      },
      {
        "id": "3",
        "description": "Third step",
        "toolName": "",
        "toolArgs": "",
        "dependsOn": ["2"]
      }
    ]
  }
  """

proc diamondPlanJson(): string =
  """
  {
    "goal": "Diamond dependency",
    "steps": [
      {
        "id": "1",
        "description": "Start",
        "toolName": "echo",
        "toolArgs": "{\"msg\": \"start\"}",
        "dependsOn": []
      },
      {
        "id": "2",
        "description": "Left",
        "toolName": "echo",
        "toolArgs": "{\"msg\": \"left\"}",
        "dependsOn": ["1"]
      },
      {
        "id": "3",
        "description": "Right",
        "toolName": "echo",
        "toolArgs": "{\"msg\": \"right\"}",
        "dependsOn": ["1"]
      },
      {
        "id": "4",
        "description": "End",
        "toolName": "echo",
        "toolArgs": "{\"msg\": \"end\"}",
        "dependsOn": ["2", "3"]
      }
    ]
  }
  """

proc noDependenciesPlanJson(): string =
  """
  {
    "goal": "Independent steps",
    "steps": [
      {
        "id": "a",
        "description": "Step A",
        "toolName": "echo",
        "toolArgs": "{\"msg\": \"a\"}",
        "dependsOn": []
      },
      {
        "id": "b",
        "description": "Step B",
        "toolName": "echo",
        "toolArgs": "{\"msg\": \"b\"}",
        "dependsOn": []
      },
      {
        "id": "c",
        "description": "Step C",
        "toolName": "echo",
        "toolArgs": "{\"msg\": \"c\"}",
        "dependsOn": []
      }
    ]
  }
  """

proc mockChatResponse(content: string): string =
  let node = %*{
    "id": "chatcmpl-1",
    "object": "chat.completion",
    "model": "test-model",
    "choices": [
      {
        "index": 0,
        "message": {"role": "assistant", "content": ""},
        "finish_reason": "stop"
      }
    ],
    "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
  }
  node["choices"][0]["message"]["content"] = %content
  node.pretty()

# ---------------------------------------------------------------------------
# Suite: parsePlan
# ---------------------------------------------------------------------------

suite "parsePlan: valid plans":
  test "parses valid 3-step plan":
    let plan = parsePlan(validPlanJson())
    check plan.goal == "Test goal"
    check plan.steps.len == 3
    check plan.steps[0].id == "1"
    check plan.steps[0].description == "First step"
    check plan.steps[0].toolName == "echo"
    check plan.steps[0].dependsOn.len == 0
    check plan.steps[1].id == "2"
    check plan.steps[1].dependsOn == @["1"]
    check plan.steps[2].id == "3"
    check plan.steps[2].toolName == ""
    check plan.steps[2].toolArgs == ""

  test "parses empty plan (0 steps)":
    let json = """{"goal": "empty goal", "steps": []}"""
    let plan = parsePlan(json)
    check plan.goal == "empty goal"
    check plan.steps.len == 0

  test "preserves step status as pending after parsing":
    let plan = parsePlan(validPlanJson())
    for step in plan.steps:
      check step.status == ssPending

suite "parsePlan: error cases":
  test "missing 'goal' field raises PlanError":
    let json = """{"steps": []}"""
    expect PlanError:
      discard parsePlan(json)

  test "missing 'steps' field raises PlanError":
    let json = """{"goal": "test"}"""
    expect PlanError:
      discard parsePlan(json)

  test "duplicate step id raises PlanError":
    let json = """
    {
      "goal": "test",
      "steps": [
        {"id": "1", "description": "a", "toolName": "", "toolArgs": "", "dependsOn": []},
        {"id": "1", "description": "b", "toolName": "", "toolArgs": "", "dependsOn": []}
      ]
    }
    """
    expect PlanError:
      discard parsePlan(json)

  test "dependency on unknown step raises PlanError":
    let json = """
    {
      "goal": "test",
      "steps": [
        {"id": "1", "description": "a", "toolName": "", "toolArgs": "", "dependsOn": ["99"]}
      ]
    }
    """
    expect PlanError:
      discard parsePlan(json)

  test "step with toolArgs but no toolName raises PlanError":
    let json = """
    {
      "goal": "test",
      "steps": [
        {
          "id": "1",
          "description": "a",
          "toolName": "",
          "toolArgs": "{\"x\": 1}",
          "dependsOn": []
        }
      ]
    }
    """
    expect PlanError:
      discard parsePlan(json)

  test "invalid JSON raises PlanError":
    expect PlanError:
      discard parsePlan("not valid json at all {")

  test "non-object root raises PlanError":
    expect PlanError:
      discard parsePlan("[1, 2, 3]")

# ---------------------------------------------------------------------------
# Suite: topoSort
# ---------------------------------------------------------------------------

suite "topoSort: linear chains":
  test "linear chain 1->2->3 produces [0,1,2]":
    let plan = parsePlan(validPlanJson())
    let order = topoSort(plan)
    check order == @[0, 1, 2]

  test "empty plan produces empty order":
    let json = """{"goal": "empty", "steps": []}"""
    let plan = parsePlan(json)
    let order = topoSort(plan)
    check order.len == 0

suite "topoSort: diamond dependency":
  test "diamond 1->{2,3}->4 produces valid topological order":
    let plan = parsePlan(diamondPlanJson())
    let order = topoSort(plan)
    # Step 0 (id "1") should come first
    check order[0] == 0
    # Step 1 (id "2") and step 2 (id "3") can come in either order, but before step 3
    check (order[1] == 1 and order[2] == 2) or (order[1] == 2 and order[2] == 1)
    # Step 3 (id "4") should come last
    check order[3] == 3

suite "topoSort: no dependencies":
  test "steps with no dependencies come in original order":
    let plan = parsePlan(noDependenciesPlanJson())
    let order = topoSort(plan)
    # All steps should be present
    check order.len == 3
    # With no dependencies, should preserve insertion order
    check order == @[0, 1, 2]

suite "topoSort: cycle detection":
  test "cycle detection raises PlanError":
    let json = """
    {
      "goal": "cycle",
      "steps": [
        {"id": "1", "description": "a", "toolName": "", "toolArgs": "", "dependsOn": ["2"]},
        {"id": "2", "description": "b", "toolName": "", "toolArgs": "", "dependsOn": ["1"]}
      ]
    }
    """
    let plan = parsePlan(json)
    expect PlanError:
      discard topoSort(plan)

# ---------------------------------------------------------------------------
# Suite: generatePlan
# ---------------------------------------------------------------------------

var sharedServer = startMockServer()

suite "generatePlan: LLM responses":
  setup:
    resetMock(sharedServer)

  test "valid plan JSON from LLM is parsed correctly":
    sharedServer.enqueue("200 OK", mockChatResponse(validPlanJson()))
    let client = makeClient(sharedServer)
    let registry = makeRegistry()
    let plan = generatePlan(client, "test goal", registry)
    check plan.goal == "Test goal"
    check plan.steps.len == 3
    check plan.steps[0].id == "1"

  test "invalid JSON from LLM raises PlanError":
    sharedServer.enqueue("200 OK", mockChatResponse("not a valid json {"))
    let client = makeClient(sharedServer)
    let registry = makeRegistry()
    expect PlanError:
      discard generatePlan(client, "test goal", registry)

  test "empty content from LLM raises PlanError":
    sharedServer.enqueue("200 OK", mockChatResponse(""))
    let client = makeClient(sharedServer)
    let registry = makeRegistry()
    expect PlanError:
      discard generatePlan(client, "test goal", registry)

  test "plan with unknown tool raises PlanError":
    let json = """
    {
      "goal": "test",
      "steps": [
        {
          "id": "1",
          "description": "a",
          "toolName": "unknownTool",
          "toolArgs": "{}",
          "dependsOn": []
        }
      ]
    }
    """
    sharedServer.enqueue("200 OK", mockChatResponse(json))
    let client = makeClient(sharedServer)
    let registry = makeRegistry()
    expect PlanError:
      discard generatePlan(client, "test goal", registry)

  test "sends goal in request messages":
    sharedServer.enqueue("200 OK", mockChatResponse(validPlanJson()))
    let client = makeClient(sharedServer)
    let registry = makeRegistry()
    discard generatePlan(client, "my test goal", registry)
    check sharedServer.requestCount == 1
    let reqJson = parseJson(sharedServer.requestBodies[0])
    let msgs = reqJson["messages"]
    # Should have system prompt and user message with the goal
    check msgs.len >= 2
    check msgs[^1]["role"].getStr() == "user"
    check msgs[^1]["content"].getStr() == "my test goal"

# ---------------------------------------------------------------------------
# Suite: executePlan
# ---------------------------------------------------------------------------

suite "executePlan: tool execution":
  setup:
    resetMock(sharedServer)

  test "3-step plan with tool calls executes in order":
    resetMock(sharedServer)
    # Two responses for reasoning step and final synthesis
    sharedServer.enqueue("200 OK", mockChatResponse("Reasoning result"))
    sharedServer.enqueue("200 OK", mockChatResponse("Final answer"))
    
    var mem = makeMemory()
    defer: mem.close()
    let client = makeClient(sharedServer)
    let registry = makeRegistry()
    let plan = parsePlan(validPlanJson())
    let cfg = defaultAgentConfig()
    
    let result = executePlan(cfg, client, registry, mem, "user request", plan)
    
    # All steps should be complete
    check result.plan.steps[0].status == ssComplete
    check result.plan.steps[1].status == ssComplete
    check result.plan.steps[2].status == ssComplete
    # Check results from echo tool
    check result.plan.steps[0].result.contains("ECHO:")
    check result.plan.steps[1].result.contains("ECHO:")
    # Synthesis step should have text
    check result.finalAnswer.len > 0
    check result.allStepsComplete
  test "step failure marks dependents as skipped":
    resetMock(sharedServer)
    sharedServer.enqueue("200 OK", mockChatResponse("Final answer"))
    
    var mem = makeMemory()
    defer: mem.close()
    let client = makeClient(sharedServer)
    # Create a tool that fails
    let failingParams = %*{"type": "object", "properties": {}, "required": []}
    let failingTool = newTool(
      name = "echo",
      description = "Failing tool",
      parameters = failingParams,
      execute = proc (args: JsonNode): ToolResult {.gcsafe, raises: [].} =
        ToolResult(output: "tool execution failed", isError: true, exitCode: 1)
    )
    let registry = newToolRegistry()
    registry.register(failingTool)
    let plan = parsePlan(validPlanJson())
    let cfg = defaultAgentConfig()
    
    let result = executePlan(cfg, client, registry, mem, "user request", plan)
    
    # First step should fail (tool returns error)
    check result.plan.steps[0].status == ssFailed
    # Steps 2 and 3 should be skipped (they depend on step 1)
    check result.plan.steps[1].status == ssSkipped
    check result.plan.steps[2].status == ssSkipped
    check not result.allStepsComplete

  test "reasoning step (empty toolName) calls LLM":
    resetMock(sharedServer)
    sharedServer.enqueue("200 OK", mockChatResponse("Reasoning output from LLM"))
    sharedServer.enqueue("200 OK", mockChatResponse("Final answer"))
    
    var mem = makeMemory()
    defer: mem.close()
    let client = makeClient(sharedServer)
    let registry = makeRegistry()
    let plan = parsePlan(validPlanJson())
    let cfg = defaultAgentConfig()
    
    let result = executePlan(cfg, client, registry, mem, "user request", plan)
    
    # Step 2 is a reasoning step (toolName is empty)
    check result.plan.steps[2].status == ssComplete
    check result.plan.steps[2].result == "Reasoning output from LLM"
    # Should have made 3 LLM calls: reasoning step + synthesis
    check sharedServer.requestCount >= 2

  test "final synthesis produces answer":
    resetMock(sharedServer)
    sharedServer.enqueue("200 OK", mockChatResponse("Synthesized final answer"))
    sharedServer.enqueue("200 OK", mockChatResponse("Final answer"))
    
    var mem = makeMemory()
    defer: mem.close()
    let client = makeClient(sharedServer)
    let registry = makeRegistry()
    let plan = parsePlan(validPlanJson())
    let cfg = defaultAgentConfig()
    
    let result = executePlan(cfg, client, registry, mem, "user request", plan)
    
    check result.finalAnswer.len > 0

  test "execution results logged to memory":
    resetMock(sharedServer)
    sharedServer.enqueue("200 OK", mockChatResponse("Reasoning"))
    sharedServer.enqueue("200 OK", mockChatResponse("Final"))
    
    var mem = makeMemory()
    defer: mem.close()
    let client = makeClient(sharedServer)
    let registry = makeRegistry()
    let plan = parsePlan(validPlanJson())
    let cfg = defaultAgentConfig()
    
    let result = executePlan(cfg, client, registry, mem, "user request", plan)
    
    # Get the session history to verify logging
    let history = mem.getHistory(result.sessionId)
    # Should have: user request, plan summary, tool results, reasoning, synthesis
    check history.len > 0
    # Check that we logged tool results
    var foundToolMessage = false
    for msg in history:
      if msg.role == crTool:
        foundToolMessage = true
        break
    check foundToolMessage

suite "executePlan: statistics":
  setup:
    resetMock(sharedServer)

  test "tracks tool calls made":
    resetMock(sharedServer)
    sharedServer.enqueue("200 OK", mockChatResponse("Reasoning"))
    sharedServer.enqueue("200 OK", mockChatResponse("Final"))
    
    var mem = makeMemory()
    defer: mem.close()
    let client = makeClient(sharedServer)
    let registry = makeRegistry()
    let plan = parsePlan(validPlanJson())
    let cfg = defaultAgentConfig()
    
    let result = executePlan(cfg, client, registry, mem, "user request", plan)
    
    # Two tool steps executed
    check result.stats.toolCallsMade == 2

  test "tracks total turns":
    resetMock(sharedServer)
    sharedServer.enqueue("200 OK", mockChatResponse("Reasoning"))
    sharedServer.enqueue("200 OK", mockChatResponse("Final"))
    
    var mem = makeMemory()
    defer: mem.close()
    let client = makeClient(sharedServer)
    let registry = makeRegistry()
    let plan = parsePlan(validPlanJson())
    let cfg = defaultAgentConfig()
    
    let result = executePlan(cfg, client, registry, mem, "user request", plan)
    
    # One turn per step (2 tool + 1 reasoning)
    check result.stats.totalTurns >= 3

# ---------------------------------------------------------------------------
# Suite: Display formatting
# ---------------------------------------------------------------------------

suite "formatPlan":
  test "produces expected output format":
    let plan = parsePlan(validPlanJson())
    let formatted = formatPlan(plan)
    check formatted.contains("Plan:")
    check formatted.contains("1.")
    check formatted.contains("2.")
    check formatted.contains("3.")
    check formatted.contains("First step")
    check formatted.contains("echo")
    check formatted.contains("depends: 1")

suite "formatStepStatus":
  test "complete step shows checkmark":
    var step = PlanStep(
      id: "1",
      description: "test",
      toolName: "echo",
      status: ssComplete,
      result: "done"
    )
    let formatted = formatStepStatus(step)
    check formatted.contains("✓")
    check formatted.contains("Step 1")

  test "failed step shows X":
    var step = PlanStep(
      id: "1",
      description: "test",
      toolName: "echo",
      status: ssFailed,
      result: "error"
    )
    let formatted = formatStepStatus(step)
    check formatted.contains("✗")

  test "skipped step shows arrow":
    var step = PlanStep(
      id: "1",
      description: "test",
      toolName: "echo",
      status: ssSkipped,
      result: ""
    )
    let formatted = formatStepStatus(step)
    check formatted.contains("→")

  test "pending step shows circle":
    var step = PlanStep(
      id: "1",
      description: "test",
      toolName: "echo",
      status: ssPending,
      result: ""
    )
    let formatted = formatStepStatus(step)
    check formatted.contains("○")

  test "reasoning step shows tool name as 'reasoning'":
    var step = PlanStep(
      id: "1",
      description: "think",
      toolName: "",
      status: ssComplete,
      result: "thought"
    )
    let formatted = formatStepStatus(step)
    check formatted.contains("reasoning")

suite "formatPlanResult":
  test "contains plan summary":
    var plan = parsePlan(validPlanJson())
    plan.steps[0].status = ssComplete
    plan.steps[0].result = "result1"
    plan.steps[1].status = ssComplete
    plan.steps[1].result = "result2"
    plan.steps[2].status = ssFailed
    plan.steps[2].result = "failed"
    
    let pr = PlanResult(
      plan: plan,
      finalAnswer: "The answer",
      allStepsComplete: false,
      sessionId: "test"
    )
    let formatted = formatPlanResult(pr)
    
    check formatted.contains("Plan Results")
    check formatted.contains("✓")
    check formatted.contains("✗")
    check formatted.contains("All steps complete: false")

  test "truncates long results":
    var plan = parsePlan(validPlanJson())
    let longResult = "x".repeat(300)
    plan.steps[0].status = ssComplete
    plan.steps[0].result = longResult
    
    let pr = PlanResult(
      plan: plan,
      finalAnswer: "The answer",
      allStepsComplete: true,
      sessionId: "test"
    )
    let formatted = formatPlanResult(pr)
    
    # Should contain truncation marker
    check formatted.contains("...")
    # Should not contain the full 300-char string
    check formatted.len < longResult.len + 100
