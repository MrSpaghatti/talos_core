## Tests for talos_core/agent_dispatcher.nim, focused on task-16's advisor
## wiring: callback-before-advisor ordering, and note round-tripping across
## two dispatched requests on the same session via the real dispatcher
## entry point (not just advisor.nim's own unit tests).

import std/[asyncdispatch, json, os, strutils, times, unittest]
import talos_core/agent_dispatcher
import talos_core/advisor
import talos_core/config
import talos_core/llm_client
import talos_core/memory
import talos_core/persona
import talos_core/tool_registry
import talos_core/testkit/mock_llm_server

const AssistantReplyBody = """
{
  "id": "chatcmpl-1",
  "object": "chat.completion",
  "model": "test-model",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "Sure, done."},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}
}
"""

proc advisorBody(content: string): string =
  """
{
  "id": "chatcmpl-2",
  "object": "chat.completion",
  "model": "advisor-model",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": """ & $(%*content) & """},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}
}
"""

let testDbPath = getTempDir() / ("talos_dispatcher_advisor_test_" &
  $getCurrentProcessId() & "_" & $epochTime() & ".db")

var sharedServer = startMockServer()

proc makeLlm(): LLMClient =
  newLLMClient(baseUrl = baseUrlFor(sharedServer), apiKey = "test", model = "test-model")

let advisorPersona = PersonaConfig(name: "advisor", systemPrompt: "Watch closely.")

suite "dispatchAgent: advisor ordering and note round-trip (task-16)":
  setup:
    resetMock(sharedServer)
    clearPendingNotes()
    if fileExists(testDbPath):
      removeFile(testDbPath)

  test "the callback fires before the advisor call, not after":
    var callbackOrder: seq[string] = @[]
    let cb = proc(r: agent_dispatcher.AgentResult) {.gcsafe, raises: [].} =
      {.cast(gcsafe), cast(raises: []).}:
        callbackOrder.add("callback")
    sharedServer.enqueue("200 OK", AssistantReplyBody)
    sharedServer.enqueue("200 OK", advisorBody("NONE"))
    let dispatcher = newAgentDispatcher(
      cb, defaultConfig(), makeLlm(), newToolRegistry(), testDbPath,
      advisorPersona = advisorPersona, advisorLlm = makeLlm(), advisorEnabled = true,
    )
    waitFor dispatchAgent(dispatcher, AgentRequest(
      userInput: "hello", sessionId: "sess-order", surfaceId: "surf-1"))
    check callbackOrder == @["callback"]
    # Both the primary turn and the advisor call actually happened.
    check sharedServer.requestCount == 2

  test "a note the advisor leaves is delivered on the NEXT dispatched request, not this one":
    let cb = proc(r: agent_dispatcher.AgentResult) {.gcsafe, raises: [].} = discard
    sharedServer.enqueue("200 OK", AssistantReplyBody)
    sharedServer.enqueue("200 OK", advisorBody("""{"note": "remember the user's timezone is UTC-5", "severity": "aside"}"""))
    let dispatcher = newAgentDispatcher(
      cb, defaultConfig(), makeLlm(), newToolRegistry(), testDbPath,
      advisorPersona = advisorPersona, advisorLlm = makeLlm(), advisorEnabled = true,
    )
    waitFor dispatchAgent(dispatcher, AgentRequest(
      userInput: "what time is it for me", sessionId: "sess-note", surfaceId: "surf-1"))

    # Not delivered on the request that produced it.
    let firstReq = parseJson(sharedServer.requestBodies[0])
    for m in firstReq["messages"]:
      check not m["content"].getStr("").contains("UTC-5")

    # A second dispatched request on the same session sees it.
    sharedServer.enqueue("200 OK", AssistantReplyBody)
    sharedServer.enqueue("200 OK", advisorBody("NONE"))
    waitFor dispatchAgent(dispatcher, AgentRequest(
      userInput: "and now?", sessionId: "sess-note", surfaceId: "surf-1"))
    let secondReq = parseJson(sharedServer.requestBodies[2])
    var found = false
    for m in secondReq["messages"]:
      if m["content"].getStr("").contains("UTC-5"):
        found = true
    check found

  test "advisorEnabled = false never calls the advisor model":
    let cb = proc(r: agent_dispatcher.AgentResult) {.gcsafe, raises: [].} = discard
    sharedServer.enqueue("200 OK", AssistantReplyBody)
    let dispatcher = newAgentDispatcher(
      cb, defaultConfig(), makeLlm(), newToolRegistry(), testDbPath,
    )
    waitFor dispatchAgent(dispatcher, AgentRequest(
      userInput: "hello", sessionId: "sess-off", surfaceId: "surf-1"))
    check sharedServer.requestCount == 1

  test "the advisor note never appears in the primary agent's persisted session history":
    let cb = proc(r: agent_dispatcher.AgentResult) {.gcsafe, raises: [].} = discard
    sharedServer.enqueue("200 OK", AssistantReplyBody)
    sharedServer.enqueue("200 OK", advisorBody("""{"note": "a secret advisor-only observation", "severity": "aside"}"""))
    let dispatcher = newAgentDispatcher(
      cb, defaultConfig(), makeLlm(), newToolRegistry(), testDbPath,
      advisorPersona = advisorPersona, advisorLlm = makeLlm(), advisorEnabled = true,
    )
    waitFor dispatchAgent(dispatcher, AgentRequest(
      userInput: "hello", sessionId: "sess-hist", surfaceId: "surf-1"))

    var mem = newMemory(testDbPath)
    defer: mem.close()
    let history = mem.getHistory("sess-hist")
    for m in history:
      check not m.content.contains("a secret advisor-only observation")

for suffix in ["", "-wal", "-shm", "-journal"]:
  let p = testDbPath & suffix
  if fileExists(p):
    try: removeFile(p) except CatchableError: discard
