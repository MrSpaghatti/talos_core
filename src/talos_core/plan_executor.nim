## Talos plan-executor.
##
## An alternative to the flat ReAct loop: ask the LLM to produce a structured
## plan up front, then execute the steps in dependency order, and synthesise
## a final answer from the accumulated results. This gives the agent better
## long-horizon coherence for tasks that benefit from decomposition.
##
## Flow:
##   1. `generatePlan` — sends a specialised prompt to the LLM asking for a
##      JSON plan with steps, tool names, tool args, and dependency edges.
##   2. `topoSort` — orders steps by `dependsOn` (Kahn's algorithm).
##   3. `executePlan` — runs each step in order:
##      - Tool steps: execute the tool via the registry, store the result.
##      - Reasoning steps (empty toolName): call the LLM with plan context
##        and previous step results.
##   4. On step failure: mark failed, skip dependents, attempt independent
##      remaining steps.
##   5. Final synthesis call: the LLM gets all step results and produces the
##      final answer.
##
## Out of scope (deferred):
##   - Parallel step execution (independent steps could run concurrently)
##   - Plan revision / re-planning mid-execution
##   - Streaming plan generation output

import std/[json, strutils, tables, sequtils]

import llm_client
import tool_registry
import memory
import agent_loop

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  StepStatus* = enum
    ssPending = "pending"
    ssRunning = "running"
    ssComplete = "complete"
    ssFailed = "failed"
    ssSkipped = "skipped"

  PlanStep* = object
    id*: string               ## "1", "2a", etc.
    description*: string      ## human-readable
    toolName*: string         ## tool to use ("" for LLM reasoning)
    toolArgs*: string         ## JSON args ("" for reasoning)
    dependsOn*: seq[string]   ## step IDs this step waits for
    status*: StepStatus
    result*: string           ## output after execution

  ExecutionPlan* = object
    goal*: string
    steps*: seq[PlanStep]

  PlanResult* = object
    plan*: ExecutionPlan
    finalAnswer*: string
    stats*: AgentStats
    allStepsComplete*: bool
    sessionId*: string

  PlanError* = object of CatchableError
    ## Raised when plan generation or parsing fails irrecoverably.

# ---------------------------------------------------------------------------
# Plan generation
# ---------------------------------------------------------------------------

const PlanSystemPrompt* = """
You are a planning agent. Given a goal and the available tools, produce a
step-by-step execution plan.

Output ONLY valid JSON — no markdown, no explanation, no code fences:
{"goal": "...", "steps": [{"id": "1", "description": "...", "toolName": "shell", "toolArgs": "{\"cmd\": \"...\"}", "dependsOn": []}, ...]}

Rules:
- Each step has a unique "id" (e.g. "1", "2", "3a").
- "toolName" is the name of a tool to call, or "" for a reasoning step
  (the LLM will think about the previous results).
- "toolArgs" is a JSON object string with the tool's arguments, or "" for
  reasoning steps.
- "dependsOn" lists step IDs that must complete before this step can run.
  Use [] for steps with no dependencies.
- Keep plans focused — typically 3-8 steps.
""".strip()

proc buildPlanRequest(
    goal: string;
    registry: ToolRegistry;
): seq[ChatMessage] =
  ## Builds the message list for plan generation: system prompt + user goal.
  var sysContent = PlanSystemPrompt
  if not registry.isNil and registry.len > 0:
    let toolNames = registry.names()
    sysContent &= "\n\nAvailable tools: " & toolNames.join(", ")
  result = @[
    ChatMessage(role: crSystem, content: sysContent),
    ChatMessage(role: crUser, content: goal),
  ]

proc parsePlan*(jsonText: string): ExecutionPlan =
  ## Parses the LLM's JSON plan response into an ExecutionPlan.
  ## Raises PlanError on malformed JSON or invalid plan structure.
  var node: JsonNode
  try:
    node = parseJson(jsonText.strip())
  except JsonParsingError as e:
    raise newException(PlanError,
      "LLM plan response is not valid JSON: " & e.msg)
  except CatchableError as e:
    raise newException(PlanError,
      "Failed to parse plan JSON: " & e.msg)

  if node.kind != JObject:
    raise newException(PlanError,
      "Plan must be a JSON object, got " & $node.kind)

  if not node.hasKey("goal") or node["goal"].kind != JString:
    raise newException(PlanError, "Plan missing 'goal' string field")
  result.goal = node["goal"].getStr()

  if not node.hasKey("steps") or node["steps"].kind != JArray:
    raise newException(PlanError, "Plan missing 'steps' array field")

  var seenIds: Table[string, bool]
  for sNode in node["steps"]:
    if sNode.kind != JObject:
      raise newException(PlanError, "Each step must be a JSON object")

    var step: PlanStep
    step.status = ssPending

    if not sNode.hasKey("id") or sNode["id"].kind != JString:
      raise newException(PlanError, "Step missing 'id' string field")
    step.id = sNode["id"].getStr()
    if step.id.len == 0:
      raise newException(PlanError, "Step id must not be empty")
    if seenIds.hasKey(step.id):
      raise newException(PlanError, "Duplicate step id: " & step.id)
    seenIds[step.id] = true

    if not sNode.hasKey("description") or sNode["description"].kind != JString:
      raise newException(PlanError, "Step '" & step.id & "' missing 'description'")
    step.description = sNode["description"].getStr()

    step.toolName = ""
    if sNode.hasKey("toolName") and sNode["toolName"].kind == JString:
      step.toolName = sNode["toolName"].getStr()

    step.toolArgs = ""
    if sNode.hasKey("toolArgs") and sNode["toolArgs"].kind == JString:
      step.toolArgs = sNode["toolArgs"].getStr()

    step.dependsOn = @[]
    if sNode.hasKey("dependsOn") and sNode["dependsOn"].kind == JArray:
      for dep in sNode["dependsOn"]:
        if dep.kind == JString:
          step.dependsOn.add(dep.getStr())

    result.steps.add(step)

  # Validate dependency references point to real step ids.
  for step in result.steps:
    for dep in step.dependsOn:
      if not seenIds.hasKey(dep):
        raise newException(PlanError,
          "Step '" & step.id & "' depends on unknown step '" & dep & "'")

  # Validate tool names exist in registry (if a registry was provided).
  # Done by the caller after parsing, since parsePlan doesn't have the
  # registry. We just validate non-empty toolName here.
  for step in result.steps:
    if step.toolName.len == 0 and step.toolArgs.len > 0:
      raise newException(PlanError,
        "Step '" & step.id & "' has toolArgs but no toolName")

proc generatePlan*(
    llm: LLMClient;
    goal: string;
    registry: ToolRegistry;
    extraParams: Table[string, JsonNode] = initTable[string, JsonNode]();
): ExecutionPlan =
  ## Asks the LLM to produce a plan for the given goal. The available tool
  ## names are included in the system prompt so the LLM knows what it can
  ## call. Raises PlanError if the LLM response can't be parsed as a plan,
  ## or LLMError if the request itself fails.
  let messages = buildPlanRequest(goal, registry)

  let resp = llm.chatCompletion(prompt = "", history = messages, extraParams = extraParams)

  if resp.content.strip().len == 0:
    raise newException(PlanError, "LLM returned empty plan response")

  result = parsePlan(resp.content)

  # Validate tool names against the registry.
  if not registry.isNil:
    for step in result.steps:
      if step.toolName.len > 0 and not registry.has(step.toolName):
        raise newException(PlanError,
          "Step '" & step.id & "' references unknown tool: " & step.toolName)

# ---------------------------------------------------------------------------
# Topological sort
# ---------------------------------------------------------------------------

proc topoSort*(plan: ExecutionPlan): seq[int] =
  ## Returns step indices in dependency order (Kahn's algorithm).
  ## Steps with no dependencies come first. Raises PlanError if a cycle
  ## is detected.
  let n = plan.steps.len
  if n == 0:
    return @[]

  # Build adjacency: stepId → index, and in-degree per index.
  var idToIdx: Table[string, int]
  for i, step in plan.steps:
    idToIdx[step.id] = i

  var inDegree = newSeq[int](n)
  var adjList = newSeq[seq[int]](n)
  for i, step in plan.steps:
    for dep in step.dependsOn:
      if not idToIdx.hasKey(dep):
        raise newException(PlanError,
          "Step '" & step.id & "' depends on unknown step '" & dep & "'")
      let depIdx = idToIdx[dep]
      adjList[depIdx].add(i)
      inc inDegree[i]

  # Start with all zero-in-degree nodes.
  var queue: seq[int] = @[]
  for i in 0 ..< n:
    if inDegree[i] == 0:
      queue.add(i)

  var head = 0
  while head < queue.len:
    let idx = queue[head]
    inc head
    result.add(idx)
    for neighbor in adjList[idx]:
      dec inDegree[neighbor]
      if inDegree[neighbor] == 0:
        queue.add(neighbor)

  if result.len != n:
    raise newException(PlanError,
      "Plan has a dependency cycle — cannot topologically sort")

# ---------------------------------------------------------------------------
# Plan execution
# ---------------------------------------------------------------------------

proc markDependentsSkipped(plan: var ExecutionPlan; failedId: string) =
  ## Recursively marks all steps that transitively depend on `failedId`
  ## as skipped (if they are still pending).
  var toProcess: seq[string] = @[failedId]
  var head = 0
  while head < toProcess.len:
    let current = toProcess[head]
    inc head
    for i, step in plan.steps:
      if step.status == ssPending and current in step.dependsOn:
        plan.steps[i].status = ssSkipped
        toProcess.add(plan.steps[i].id)

proc buildStepContext(plan: ExecutionPlan; currentIdx: int): string =
  ## Builds a text summary of completed step results for the LLM context
  ## in a reasoning step. Includes only steps that the current step
  ## depends on (transitively) and are complete.
  var idToIdx: Table[string, int]
  for i, step in plan.steps:
    idToIdx[step.id] = i

  # Collect transitive dependencies.
  var relevantIds: Table[string, bool]
  proc collectDeps(stepId: string) =
    if relevantIds.hasKey(stepId): return
    relevantIds[stepId] = true
    let idx = idToIdx[stepId]
    for dep in plan.steps[idx].dependsOn:
      collectDeps(dep)

  for dep in plan.steps[currentIdx].dependsOn:
    collectDeps(dep)

  var lines: seq[string] = @[]
  for i, step in plan.steps:
    if relevantIds.hasKey(step.id) and step.status == ssComplete:
      lines.add("Step " & step.id & " [" & step.toolName & "]: " & step.result)
  if lines.len == 0:
    return "(no prior step results)"
  return lines.join("\n")

proc executePlan*(
    agentCfg: AgentConfig;
    llm: LLMClient;
    registry: ToolRegistry;
    memory: var Memory;
    userInput: string;
    plan: ExecutionPlan;
    resumeSessionId: string = "";
    stepCallback: proc(step: PlanStep) {.gcsafe, raises: [].} = nil;
): PlanResult =
  ## Executes a plan step-by-step in dependency order. Each tool step is
  ## executed via the registry; each reasoning step calls the LLM with the
  ## context of prior step results. After all steps, a final synthesis call
  ## produces the answer. Results are logged to memory.
  let sid =
    if resumeSessionId.len > 0: resumeSessionId
    else: memory.newSession()
  result.sessionId = sid
  result.plan = plan

  # If resuming, the session row must exist before the first appendMessage
  # below — mirrors agent_loop.runAgentLoop, which does the same for a
  # caller-minted session ID that has no row yet.
  if resumeSessionId.len > 0:
    memory.ensureSession(sid)

  # Log the user's goal and the plan.
  let userMsg = ChatMessage(role: crUser, content: userInput)
  memory.appendMessage(sid, userMsg)

  let planSummary = "Plan:\n" & plan.steps.mapIt(
    "  " & it.id & ". [" &
    (if it.toolName.len > 0: it.toolName else: "reasoning") &
    "] " & it.description
  ).join("\n")
  let planMsg = ChatMessage(role: crAssistant, content: planSummary)
  memory.appendMessage(sid, planMsg)

  let order = topoSort(plan)
  let maxIter = max(1, agentCfg.maxIterations)

  for stepIdx in order:
    if result.stats.totalTurns >= maxIter:
      break

    var step = result.plan.steps[stepIdx]

    # Skip if already marked (e.g. by a failed dependency).
    if step.status != ssPending:
      if stepCallback != nil:
        stepCallback(step)
      continue

    step.status = ssRunning
    result.plan.steps[stepIdx] = step

    if agentCfg.turnCallback != nil:
      agentCfg.turnCallback()
    inc result.stats.totalTurns

    if step.toolName.len > 0:
      # --- Tool step ---
      inc result.stats.toolCallsMade
      if registry.isNil:
        # Mirrors agent_loop.executeToolCall's nil-registry guard — without
        # it, registry.execute on a nil ToolRegistry segfaults the process
        # rather than failing this step gracefully (a segfault can't be
        # caught by `except ToolError` below).
        step.status = ssFailed
        step.result = "no tool registry configured"
        result.plan.steps[stepIdx] = step
        result.plan.markDependentsSkipped(step.id)
        let toolMsg = ChatMessage(
          role: crTool,
          name: step.toolName,
          content: step.result,
        )
        memory.appendMessage(sid, toolMsg)
        if stepCallback != nil:
          stepCallback(step)
        continue
      try:
        let toolResult = registry.execute(step.toolName, step.toolArgs)
        if toolResult.isError:
          step.status = ssFailed
          step.result = if toolResult.output.len > 0: toolResult.output
                        else: "tool failed (exit code " & $toolResult.exitCode & ")"
          result.plan.steps[stepIdx] = step
          result.plan.markDependentsSkipped(step.id)
        else:
          step.status = ssComplete
          step.result = toolResult.output
          result.plan.steps[stepIdx] = step
      except ToolError as e:
        step.status = ssFailed
        step.result = "tool error: " & e.msg
        result.plan.steps[stepIdx] = step
        result.plan.markDependentsSkipped(step.id)

      # Log to memory.
      let toolMsg = ChatMessage(
        role: crTool,
        name: step.toolName,
        content: step.result,
      )
      memory.appendMessage(sid, toolMsg)

      if stepCallback != nil:
        stepCallback(step)
    else:
      # --- Reasoning step ---
      let context = buildStepContext(result.plan, stepIdx)
      let reasoningPrompt = "Step " & step.id & ": " & step.description &
        "\n\nPrior results:\n" & context &
        "\n\nProvide your reasoning for this step."
      let reasoningMessages = @[
        ChatMessage(role: crSystem, content: agentCfg.systemPrompt),
        ChatMessage(role: crUser, content: reasoningPrompt),
      ]

      try:
        let resp = llm.chatCompletion(prompt = "", history = reasoningMessages)
        result.stats.promptTokens += resp.usage.promptTokens
        result.stats.completionTokens += resp.usage.completionTokens
        result.stats.totalTokens += resp.usage.totalTokens
        step.status = ssComplete
        step.result = resp.content
        result.plan.steps[stepIdx] = step

        let asstMsg = ChatMessage(role: crAssistant, content: resp.content)
        memory.appendMessage(sid, asstMsg,
          tokensIn = resp.usage.promptTokens,
          tokensOut = resp.usage.completionTokens)
      except LLMError as e:
        step.status = ssFailed
        step.result = "LLM error: " & e.msg
        result.plan.steps[stepIdx] = step
        result.plan.markDependentsSkipped(step.id)

      if stepCallback != nil:
        stepCallback(step)

  # Check if all steps completed.
  result.allStepsComplete = result.plan.steps.allIt(it.status == ssComplete)

  # --- Final synthesis ---
  var synthesisParts: seq[string] = @[]
  synthesisParts.add("Goal: " & plan.goal)
  synthesisParts.add("")
  for step in result.plan.steps:
    let statusStr = $step.status
    let toolStr = if step.toolName.len > 0: step.toolName else: "reasoning"
    synthesisParts.add("Step " & step.id & " [" & toolStr & "] (" & statusStr & "):")
    synthesisParts.add(step.result)
    synthesisParts.add("")

  let synthesisPrompt = """
Based on the following step results, provide a final answer to the original goal.
If some steps failed, explain what went wrong and what was accomplished.

""" & synthesisParts.join("\n")

  let synthesisMessages = @[
    ChatMessage(role: crSystem, content: agentCfg.systemPrompt),
    ChatMessage(role: crUser, content: synthesisPrompt),
  ]

  try:
    var resp: ChatResponse
    if agentCfg.streamCallback != nil:
      resp = llm.chatCompletionStream(
        prompt = "",
        history = synthesisMessages,
        onEvent = agentCfg.streamCallback,
      )
    else:
      resp = llm.chatCompletion(prompt = "", history = synthesisMessages)
    result.finalAnswer = resp.content
    result.stats.promptTokens += resp.usage.promptTokens
    result.stats.completionTokens += resp.usage.completionTokens
    result.stats.totalTokens += resp.usage.totalTokens

    let finalMsg = ChatMessage(role: crAssistant, content: result.finalAnswer)
    memory.appendMessage(sid, finalMsg,
      tokensIn = resp.usage.promptTokens,
      tokensOut = resp.usage.completionTokens)
  except LLMError as e:
    result.finalAnswer = "Plan executed but final synthesis failed: " & e.msg
    let errMsg = ChatMessage(role: crAssistant, content: result.finalAnswer)
    memory.appendMessage(sid, errMsg)

# ---------------------------------------------------------------------------
# Plan display (for CLI)
# ---------------------------------------------------------------------------

proc formatPlan*(plan: ExecutionPlan): string =
  ## Returns a human-readable plan summary for CLI display.
  result = "Plan:"
  for step in plan.steps:
    let toolLabel = if step.toolName.len > 0: step.toolName else: "reasoning"
    result &= "\n  " & step.id & ". [" & toolLabel & "] " & step.description
    if step.dependsOn.len > 0:
      result &= " (depends: " & step.dependsOn.join(", ") & ")"
  result &= "\nExecuting..."

proc formatStepStatus*(step: PlanStep): string =
  ## Returns a one-line status string for a completed step.
  let icon = case step.status
    of ssComplete: "✓"
    of ssFailed: "✗"
    of ssSkipped: "→"
    of ssPending: "○"
    of ssRunning: "…"
  let toolLabel = if step.toolName.len > 0: step.toolName else: "reasoning"
  result = icon & " Step " & step.id & " [" & toolLabel & "] " & step.description

proc formatPlanResult*(pr: PlanResult): string =
  ## Returns a summary of the plan execution result.
  result = "\n--- Plan Results ---\n"
  for step in pr.plan.steps:
    result &= formatStepStatus(step) & "\n"
    if step.result.len > 0:
      let truncated = if step.result.len > 200:
        step.result[0 ..< 197] & "..."
      else:
        step.result
      result &= "  " & truncated & "\n"
  result &= "\nAll steps complete: " & $pr.allStepsComplete
