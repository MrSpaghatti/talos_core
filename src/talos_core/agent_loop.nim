## Talos ReAct agent loop.
##
## Implements a simple Reason+Act loop on top of the OpenAI-compatible
## Chat Completions client (`talos_core/llm_client`), a `ToolRegistry`
## (`talos_core/tool_registry`), and the SQLite-backed `Memory`
## (`talos_core/memory`).
##
## The loop:
##   1. Creates a new memory session for the run, or resumes an existing
##      one (with its prior history) when `resumeSessionId` is given.
##   2. Builds a message history: `system` + `user`.
##   3. Calls the LLM with the registered tool definitions.
##   4. If the LLM returns text (`finish_reason == "stop"`), returns the text.
##   5. If the LLM returns tool calls (`finish_reason == "tool_calls"`),
##      executes each tool through the registry, appends results as `tool`
##      messages, and loops.
##   6. Stops with a synthetic message after `maxIterations` turns or if
##      loop detection fires (the same tool is called identically N times
##      in a row, configurable via `loopDetectionThreshold`).
##   7. Logs every assistant / tool / user message to memory along with
##      token counts reported by the LLM.
##
## Out of scope (deferred):
##   - Plan-Execute
##   - Reflection / self-critique
##   - Streaming responses
##   - Vector memory / semantic retrieval

import std/[json, strutils, tables]

import config
import llm_client
import tool_registry
import memory
import persona
import delegate

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

const
  DefaultLoopDetectionThreshold* = 3
    ## A tool is considered "looping" if invoked with identical arguments
    ## this many times in a row (counting the latest call).

  DefaultSystemPrompt* = """
You are Talos, a helpful AI assistant. You can use tools to help answer

When you need to use a tool, respond with tool_calls. Otherwise, respond
with text.

Think step by step. If a tool fails, try a different approach. If you get
stuck, ask for clarification.
""".strip()

type
  AgentConfig* = object
    ## Per-run agent configuration. `maxIterations` defaults to
    ## `TalosConfig.maxLoopIterations` when constructing via
    maxIterations*: int
    loopDetectionThreshold*: int
    systemPrompt*: string
    persona*: PersonaConfig
      ## Optional persona template. If set, the persona's memory scope
      ## and delegation config are enforced during the run.
    delegation*: DelegationConfig
      ## Delegation safety bounds. Determines whether this agent can
      ## spawn children and how deep nesting can go.
    streamCallback*: OnStreamEvent
      ## If non-nil, the agent loop uses chatCompletionStream instead of
      ## chatCompletion, delivering token-by-token deltas to this callback.
    turnCallback*: proc() {.gcsafe, raises: [].}
      ## If non-nil, called once at the start of every ReAct iteration
      ## (before the LLM call). Used by callers with a "the agent is
      ## still working" indicator (e.g. Discord's typing status, which
      ## expires after ~10s) to refresh it once per turn. Since each turn
      ## blocks synchronously on the LLM call, this can't fire *during*
      ## a single slow call — only between turns.

  AgentStats* = object
    ## Counters returned alongside the agent response, useful for tests
    ## and for surfacing cost/usage to the user.
    totalTokens*: int
    promptTokens*: int
    completionTokens*: int
    totalTurns*: int
    toolCallsMade*: int

  AgentStopReason* = enum
    asrFinished       = "finished"
    asrMaxIterations  = "max_iterations"
    asrLoopDetected   = "loop_detected"
    asrError          = "error"

  AgentResult* = object
    ## Full agent response. `text` is the user-facing answer; the rest is
    ## metadata for logging / observability.
    text*: string
    sessionId*: string
    stopReason*: AgentStopReason
    stats*: AgentStats

  AgentLoopError* = object of CatchableError
    ## Raised when the agent loop cannot make progress for a reason that
    ## is not a simple LLM/tool error (e.g. inability to log to memory).

# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------

proc newAgentConfig*(
    cfg: TalosConfig;
    loopDetectionThreshold: int = DefaultLoopDetectionThreshold;
    systemPrompt: string = DefaultSystemPrompt;
): AgentConfig =
  ## Builds an AgentConfig from a TalosConfig, defaulting `maxIterations`
  ## to `cfg.maxLoopIterations` and overriding only when needed.
  AgentConfig(
    maxIterations:
      if cfg.maxLoopIterations > 0: cfg.maxLoopIterations
      else: DefaultMaxLoopIterations,
    loopDetectionThreshold:
      if loopDetectionThreshold > 0: loopDetectionThreshold
      else: DefaultLoopDetectionThreshold,
    systemPrompt: systemPrompt,
  )

proc defaultAgentConfig*(): AgentConfig =
  ## A reasonable default AgentConfig that does not depend on a loaded
  ## TalosConfig. Useful for tests and embedded use.
  AgentConfig(
    maxIterations: DefaultMaxLoopIterations,
    loopDetectionThreshold: DefaultLoopDetectionThreshold,
    systemPrompt: DefaultSystemPrompt,
    delegation: defaultDelegationConfig(),
  )

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc buildToolsParam(reg: ToolRegistry): JsonNode =
  ## Returns the JSON value for the `tools` field of a chat completions
  ## request, or `nil` if the registry is empty.
  if reg.isNil or reg.len == 0:
    return nil
  reg.toOpenAIDefinitions()

proc toolCallSignature(tc: ToolCall): string =
  ## A canonical signature used for loop detection. Two tool calls with
  ## the same name and arguments produce the same signature even if their
  ## ids differ.
  tc.name & "\x1f" & tc.arguments.strip()

proc detectLoop(
    history: seq[string];
    threshold: int;
): bool =
  ## Returns true if the last `threshold` entries in `history` are all
  ## non-empty and identical. `history` is the chronological sequence of
  ## tool-call signatures issued by the assistant.
  if threshold <= 0:
    return false
  if history.len < threshold:
    return false
  let last = history[^1]
  if last.len == 0:
    return false
  for i in 1 ..< threshold:
    if history[history.len - 1 - i] != last:
      return false
  return true

proc formatToolResult(res: ToolResult): string =
  ## Produces the text content fed back to the LLM as a `tool` message.
  ## We deliberately keep this small and plain: the LLM only needs the
  ## tool's textual output plus an explicit error marker when relevant.
  if res.isError:
    if res.output.len > 0:
      return "ERROR: " & res.output
    return "ERROR: tool failed with exit code " & $res.exitCode
  res.output

proc executeToolCall(
    reg: ToolRegistry;
    tc: ToolCall;
): ToolResult =
  ## Runs a single tool call. The registry already converts arbitrary
  ## exceptions into `ToolResult{isError:true}`, so the only case we have
  ## to handle here is a tool that is not registered at all.
  if reg.isNil:
    return ToolResult(
      output: "no tool registry configured",
      isError: true,
      exitCode: -1,
    )
  if not reg.has(tc.name):
    return ToolResult(
      output: "tool '" & tc.name & "' is not registered",
      isError: true,
      exitCode: -1,
    )
  reg.execute(tc.name, tc.arguments)

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

proc runAgentLoop*(
    agentCfg: AgentConfig;
    llm: LLMClient;
    registry: ToolRegistry;
    memory: var Memory;
    userInput: string;
    extraParams: Table[string, JsonNode] = initTable[string, JsonNode]();
    resumeSessionId: string = "";
): AgentResult =
  ## Runs the ReAct loop to convergence.
  ##
  ## Returns once the LLM emits a final text answer, the iteration limit
  ## is reached, or loop detection fires. Tool errors do *not* terminate
  ## the loop — they are reported back to the LLM as tool messages so the
  ## model can recover.
  ##
  ## If `resumeSessionId` is non-empty, that session is resumed instead of
  ## starting a fresh one: its prior messages (if any) are loaded from
  ## `memory` and used as the base of this turn's history, so a caller that
  ## tracks a stable session ID across calls (e.g. one Discord thread) gets
  ## real multi-turn continuity. The session row is created on first use if
  ## it doesn't exist yet (the caller may mint the ID before any messages
  ## have been logged against it).
  let sid =
    if resumeSessionId.len > 0: resumeSessionId
    else: memory.newSession()
  result.sessionId = sid
  result.stopReason = asrError    # overwritten below

  var messages: seq[ChatMessage] = @[]
  if resumeSessionId.len > 0:
    memory.ensureSession(sid)
    messages = memory.getHistory(sid)

  # First turn on this session: seed the system prompt.
  if messages.len == 0 and agentCfg.systemPrompt.len > 0:
    let sysMsg = ChatMessage(role: crSystem, content: agentCfg.systemPrompt)
    messages.add(sysMsg)
    memory.appendMessage(sid, sysMsg)

  let userMsg = ChatMessage(role: crUser, content: userInput)
  messages.add(userMsg)
  memory.appendMessage(sid, userMsg)

  # Tool definitions are built once: the registry shouldn't mutate during
  # a single agent run.
  let toolsParam = buildToolsParam(registry)
  var perRequestParams = extraParams
  if not toolsParam.isNil:
    perRequestParams["tools"] = toolsParam

  var toolCallHistory: seq[string] = @[]
  let maxIter = max(1, agentCfg.maxIterations)
  let loopThreshold = max(1, agentCfg.loopDetectionThreshold)

  for iteration in 1 .. maxIter:
    if agentCfg.turnCallback != nil:
      agentCfg.turnCallback()
    inc result.stats.totalTurns

    var resp: ChatResponse
    try:
      if agentCfg.streamCallback != nil:
        resp = llm.chatCompletionStream(
          prompt = "",
          history = messages,
          extraParams = perRequestParams,
          onEvent = agentCfg.streamCallback,
        )
      else:
        resp = llm.chatCompletion(
          prompt = "",
          history = messages,
          extraParams = perRequestParams,
        )
    except LLMError as e:
      let errText = "LLM request failed: " & e.msg
      let errMsg = ChatMessage(role: crAssistant, content: errText)
      memory.appendMessage(sid, errMsg)
      result.text = errText
      result.stopReason = asrError
      return

    # Track usage.
    result.stats.promptTokens     += resp.usage.promptTokens
    result.stats.completionTokens += resp.usage.completionTokens
    result.stats.totalTokens      += resp.usage.totalTokens

    # Persist the assistant message before doing anything else so even
    # if a tool blows up the conversation is recoverable from memory.
    let assistantMsg = ChatMessage(
      role: crAssistant,
      content: resp.content,
      toolCalls: resp.toolCalls,
    )
    memory.appendMessage(
      sid,
      assistantMsg,
      tokensIn = resp.usage.promptTokens,
      tokensOut = resp.usage.completionTokens,
    )
    messages.add(assistantMsg)

    # Did the model finish?
    let isToolCallTurn =
      resp.toolCalls.len > 0 or
      resp.finishReason.toLowerAscii() == "tool_calls"

    if not isToolCallTurn:
      # Treat anything that isn't tool_calls as a final answer. This
      # includes "stop", "length", and unknown finish_reasons; we surface
      # whatever text the model gave us.
      result.text = resp.content
      result.stopReason = asrFinished
      return

    # Execute every tool call requested in this turn, in order. The
    # OpenAI protocol requires one `tool` message per `tool_call` id.
    for tc in resp.toolCalls:
      inc result.stats.toolCallsMade
      toolCallHistory.add(toolCallSignature(tc))

      let toolRes = executeToolCall(registry, tc)
      let toolMsg = ChatMessage(
        role: crTool,
        name: tc.name,
        toolCallId: tc.id,
        content: formatToolResult(toolRes),
      )
      memory.appendMessage(sid, toolMsg)
      messages.add(toolMsg)

    # Loop detection runs *after* executing this turn's tool calls so we
    # always send the tool results back at least once before bailing.
    if detectLoop(toolCallHistory, loopThreshold):
      let stopText =
        "Loop detected: tool '" &
        resp.toolCalls[^1].name &
        "' was called " & $loopThreshold &
        " times with identical arguments. Stopping."
      let stopMsg = ChatMessage(role: crAssistant, content: stopText)
      memory.appendMessage(sid, stopMsg)
      result.text = stopText
      result.stopReason = asrLoopDetected
      return

  # Fell off the end of the loop without a final text answer.
  let stopText = "Max iterations reached (" & $maxIter & "). Stopping."
  let stopMsg = ChatMessage(role: crAssistant, content: stopText)
  memory.appendMessage(sid, stopMsg)
  result.text = stopText
  result.stopReason = asrMaxIterations

# ---------------------------------------------------------------------------
# Convenience overloads
# ---------------------------------------------------------------------------

proc runAgentLoop*(
    cfg: TalosConfig;
    llm: LLMClient;
    registry: ToolRegistry;
    memory: var Memory;
    userInput: string;
): AgentResult =
  ## Convenience wrapper that builds an AgentConfig from a TalosConfig.
  let agentCfg = newAgentConfig(cfg)
  runAgentLoop(agentCfg, llm, registry, memory, userInput)
