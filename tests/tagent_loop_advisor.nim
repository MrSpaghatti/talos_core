## Tests for agent_loop.nim's `AgentConfig.advisorNote` field (task-16) —
## the delivery mechanism that gets an advisor's note into the primary
## agent's next-turn LLM input without ever persisting it.
##
## Unlike talos_agent/tests/tagent_loop.nim's full ReAct-loop harness
## (built around the async mock_server.nim), this only needs to prove two
## narrow things: the note reaches the LLM request, and it never reaches
## memory. `testkit/mock_llm_server.nim`'s synchronous thread-based mock
## (used by tllm_client.nim et al.) is a much simpler fit for that.

import std/[json, strutils, unittest]
import talos_core/agent_loop
import talos_core/llm_client
import talos_core/memory
import talos_core/testkit/mock_llm_server

const SuccessBody = """
{
  "id": "chatcmpl-1",
  "object": "chat.completion",
  "model": "test-model",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "Understood."},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}
}
"""

var sharedServer = startMockServer()

proc makeClient(): LLMClient =
  newLLMClient(baseUrl = baseUrlFor(sharedServer), apiKey = "test", model = "test-model")

suite "AgentConfig.advisorNote injection":
  setup:
    resetMock(sharedServer)

  test "no advisorNote set: no advisor-note system message is sent":
    var mem = newMemory()
    var agentCfg = defaultAgentConfig()
    sharedServer.enqueue("200 OK", SuccessBody)
    discard runAgentLoop(agentCfg, makeClient(), nil, mem, "hello")
    let reqJson = parseJson(sharedServer.requestBodies[0])
    for m in reqJson["messages"]:
      check not m["content"].getStr("").contains("Advisor note")

  test "advisorNote set: an advisor-note system message is included in the LLM request":
    var mem = newMemory()
    var agentCfg = defaultAgentConfig()
    agentCfg.advisorNote = "You already checked this file, no need to re-read it."
    sharedServer.enqueue("200 OK", SuccessBody)
    discard runAgentLoop(agentCfg, makeClient(), nil, mem, "hello")
    let reqJson = parseJson(sharedServer.requestBodies[0])
    var found = false
    for m in reqJson["messages"]:
      if m["content"].getStr("").contains("You already checked this file"):
        found = true
    check found

  test "the advisor note is never persisted to memory":
    var mem = newMemory()
    var agentCfg = defaultAgentConfig()
    agentCfg.advisorNote = "a note that must not leak into history"
    sharedServer.enqueue("200 OK", SuccessBody)
    let res = runAgentLoop(agentCfg, makeClient(), nil, mem, "hello")
    let history = mem.getHistory(res.sessionId)
    for m in history:
      check not m.content.contains("a note that must not leak into history")

  test "advisorNote is injected on a resumed session too":
    var mem = newMemory()
    var firstCfg = defaultAgentConfig()
    sharedServer.enqueue("200 OK", SuccessBody)
    let first = runAgentLoop(firstCfg, makeClient(), nil, mem, "first turn")

    var secondCfg = defaultAgentConfig()
    secondCfg.advisorNote = "watch out for X"
    sharedServer.enqueue("200 OK", SuccessBody)
    discard runAgentLoop(secondCfg, makeClient(), nil, mem, "second turn",
      resumeSessionId = first.sessionId)
    let reqJson = parseJson(sharedServer.requestBodies[1])
    var found = false
    for m in reqJson["messages"]:
      if m["content"].getStr("").contains("watch out for X"):
        found = true
    check found
    # And still never persisted, even on a resumed session.
    let history = mem.getHistory(first.sessionId)
    for m in history:
      check not m.content.contains("watch out for X")
