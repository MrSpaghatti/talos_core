## Talos agent dispatcher.
##
## Bridges the async Dimscord event loop with synchronous agent processing.
## dispatchAgent calls agent_loop.runAgentLoop directly and synchronously —
## this blocks the Discord event loop during agent execution, acceptable
## for a single-user bot.
##
## NOTE: Threaded dispatch was evaluated as part of the agent-loop
## relocation (Task 1). dimscord still cannot be compiled with
## --threads:on, so the dispatcher remains synchronous.

import std/[asyncdispatch, options]
import config, llm_client, tool_registry, agent_loop, memory

type
  AgentRequest* = object
    userInput*: string
    sessionId*: string
    channelId*: string
    threadId*: string

  AgentResult* = object
    responseText*: string
    error*: Option[string]
    channelId*: string

  AgentCallback* = proc(result: AgentResult) {.gcsafe, raises: [].}

  TurnCallback* = proc(channelId: string) {.gcsafe, raises: [].}
    ## Called once at the start of every ReAct iteration during a dispatch,
    ## with the request's channelId. Used to refresh a "still working"
    ## indicator (e.g. Discord typing status) on long multi-turn runs.

  AgentDispatcher* = ref object
    callback*: AgentCallback
    cfg*: TalosConfig
    llm*: LLMClient
    reg*: ToolRegistry
    dbPath*: string
    active*: bool   ## true once cfg/llm/reg/dbPath are populated (production mode)
    turnCallback*: TurnCallback


proc newAgentDispatcher*(callback: AgentCallback): AgentDispatcher =
  ## Simplified constructor for tests. The dispatcher will echo back the
  ## request (placeholder behaviour) since it has no LLM/config to run a
  ## real agent loop against.
  AgentDispatcher(callback: callback, active: false)

proc newAgentDispatcher*(callback: AgentCallback; cfg: TalosConfig;
                          llm: LLMClient; reg: ToolRegistry; dbPath: string;
                          turnCallback: TurnCallback = nil): AgentDispatcher =
  ## Full constructor for production use (talos daemon).
  ## The callback is invoked on the event-loop thread when processing completes.
  AgentDispatcher(
    callback: callback, cfg: cfg, llm: llm, reg: reg, dbPath: dbPath, active: true,
    turnCallback: turnCallback
  )

proc dispatchAgent*(dispatcher: AgentDispatcher; request: AgentRequest): Future[void] {.async, gcsafe.} =
  ## Dispatches an agent request. In production mode, opens the memory
  ## store and runs a real agent loop synchronously, resuming
  ## `request.sessionId` (with its prior message history) if it's set —
  ## this is what gives a Discord thread's turns real continuity instead
  ## of each message starting a fresh, historyless conversation. In
  ## test/placeholder mode (no cfg/llm/reg), echoes the input back.
  ##
  ## FUTURE: This should spawn a worker thread. Blocked on dimscord's
  ## GC-safety with --threads:on.
  var result: AgentResult
  result.channelId = request.channelId

  if dispatcher.active:
    {.cast(gcsafe), cast(raises: []).}:
      try:
        var mem = newMemory(dispatcher.dbPath)
        defer: mem.close()
        var agentCfg = newAgentConfig(dispatcher.cfg)
        if dispatcher.turnCallback != nil:
          let channelId = request.channelId
          let cb = dispatcher.turnCallback
          agentCfg.turnCallback = proc() {.gcsafe, raises: [].} = cb(channelId)
        let agentResult = runAgentLoop(agentCfg, dispatcher.llm, dispatcher.reg,
                                        mem, request.userInput,
                                        resumeSessionId = request.sessionId)
        result.responseText = agentResult.text
        if agentResult.stopReason == asrError:
          result.error = some(agentResult.text)
      except CatchableError as e:
        result.responseText = e.msg
        result.error = some(e.msg)
  else:
    # Placeholder: used by tests that construct via newAgentDispatcher(callback)
    result.responseText = "Agent response for: " & request.userInput

  if dispatcher.callback != nil:
    dispatcher.callback(result)

proc startDispatcher*(dispatcher: AgentDispatcher) =
  ## Starts the dispatcher. Currently a no-op.
  discard

proc stopDispatcher*(dispatcher: AgentDispatcher) =
  ## Stops the dispatcher. Currently a no-op.
  discard
