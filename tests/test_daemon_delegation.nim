import unittest, asyncdispatch, options, strutils, os, times
import talos_core/agent_dispatcher
import talos_core/discord_types
import talos_core/config
import talos_core/tool_registry
import mock_llm_server

suite "daemon delegation config":
  test "daemonDelegation defaults to false":
    let cfg = defaultDiscordConfig()
    check cfg.daemonDelegation == false

const SuccessBody = """
{
  "id": "chatcmpl-1",
  "object": "chat.completion",
  "model": "test-model",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "hello from agent"},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8}
}
"""

suite "agent dispatcher — production path (real runAgentLoop)":
  setup:
    var server {.inject.} = startMockServer()

  teardown:
    stopMockServer(server)

  test "dispatcher runs a real agent loop and produces a result via callback":
    server.enqueue("200 OK", SuccessBody)
    var received: agent_dispatcher.AgentResult
    let cb = proc(r: agent_dispatcher.AgentResult) {.gcsafe, closure, raises: [].} =
      {.cast(gcsafe), cast(raises: []).}:
        received = r

    let dispatcher = newAgentDispatcher(
      cb, defaultConfig(), makeClient(server), newToolRegistry(), ":memory:")
    let request = AgentRequest(
      userInput: "hello",
      sessionId: "sess_1",
      channelId: "chan_1",
      threadId: "thread_1"
    )
    waitFor dispatchAgent(dispatcher, request)
    check received.responseText == "hello from agent"
    check received.error.isNone
    check received.channelId == "chan_1"

  test "dispatcher propagates LLM errors as AgentResult.error":
    server.enqueue("500 Internal Server Error",
      """{"error": {"message": "upstream exploded"}}""")
    var received: agent_dispatcher.AgentResult
    let cb = proc(r: agent_dispatcher.AgentResult) {.gcsafe, closure, raises: [].} =
      {.cast(gcsafe), cast(raises: []).}:
        received = r

    let dispatcher = newAgentDispatcher(
      cb, defaultConfig(), makeClient(server, maxRetries = 1),
      newToolRegistry(), ":memory:")
    let request = AgentRequest(
      userInput: "test",
      sessionId: "sess_2",
      channelId: "chan_2",
      threadId: "thread_2"
    )
    waitFor dispatchAgent(dispatcher, request)
    check received.error.isSome
    check received.channelId == "chan_2"

  test "dispatcher sends the real user input to the LLM":
    server.enqueue("200 OK", SuccessBody)
    let cb = proc(r: agent_dispatcher.AgentResult) {.gcsafe, closure, raises: [].} = discard

    let dispatcher = newAgentDispatcher(
      cb, defaultConfig(), makeClient(server), newToolRegistry(), ":memory:")
    let request = AgentRequest(
      userInput: "custom input",
      sessionId: "sess_3",
      channelId: "chan_3",
      threadId: "thread_3"
    )
    waitFor dispatchAgent(dispatcher, request)
    check server.requestCount == 1
    check "custom input" in server.requestBodies[0]

  test "callback receives result synchronously":
    server.enqueue("200 OK", SuccessBody)
    var resultReceived = false
    let cb = proc(r: agent_dispatcher.AgentResult) {.gcsafe, closure, raises: [].} =
      {.cast(gcsafe), cast(raises: []).}:
        resultReceived = true

    let dispatcher = newAgentDispatcher(
      cb, defaultConfig(), makeClient(server), newToolRegistry(), ":memory:")
    let request = AgentRequest(
      userInput: "sync test",
      sessionId: "sess_4",
      channelId: "chan_4",
      threadId: "thread_4"
    )
    waitFor dispatchAgent(dispatcher, request)
    check resultReceived == true

  test "turnCallback fires once per ReAct turn with the request's channelId":
    server.enqueue("200 OK", SuccessBody)
    var turnCalls: seq[string] = @[]
    let cb = proc(r: agent_dispatcher.AgentResult) {.gcsafe, closure, raises: [].} = discard
    let turnCb = proc(channelId: string) {.gcsafe, closure, raises: [].} =
      {.cast(gcsafe), cast(raises: []).}:
        turnCalls.add(channelId)

    let dispatcher = newAgentDispatcher(
      cb, defaultConfig(), makeClient(server), newToolRegistry(), ":memory:",
      turnCallback = turnCb)
    let request = AgentRequest(
      userInput: "hello",
      sessionId: "sess_5",
      channelId: "chan_typing",
      threadId: "thread_5"
    )
    waitFor dispatchAgent(dispatcher, request)
    check turnCalls == @["chan_typing"]

suite "agent dispatcher — session continuity across dispatches":
  setup:
    var server {.inject.} = startMockServer()
    let dbPath {.inject.} =
      getTempDir() / ("talos_dispatch_test_" & $getTime().toUnix() &
                       "_" & $getCurrentProcessId() & ".db")
    for suffix in ["", "-wal", "-shm"]:
      try: removeFile(dbPath & suffix)
      except OSError: discard

  teardown:
    stopMockServer(server)
    for suffix in ["", "-wal", "-shm"]:
      try: removeFile(dbPath & suffix)
      except OSError: discard

  test "a second dispatch with the same sessionId resumes the first turn's history":
    server.enqueue("200 OK", SuccessBody)
    server.enqueue("200 OK", SuccessBody)
    var received: agent_dispatcher.AgentResult
    let cb = proc(r: agent_dispatcher.AgentResult) {.gcsafe, closure, raises: [].} =
      {.cast(gcsafe), cast(raises: []).}:
        received = r

    let dispatcher = newAgentDispatcher(
      cb, defaultConfig(), makeClient(server), newToolRegistry(), dbPath)

    waitFor dispatchAgent(dispatcher, AgentRequest(
      userInput: "first turn from the thread",
      sessionId: "sess_discord_thread_1",
      channelId: "chan_1",
      threadId: "thread_1",
    ))
    check received.error.isNone

    waitFor dispatchAgent(dispatcher, AgentRequest(
      userInput: "second turn from the thread",
      sessionId: "sess_discord_thread_1",
      channelId: "chan_1",
      threadId: "thread_1",
    ))
    check received.error.isNone

    # Two dispatches, same sessionId → the second LLM request must carry
    # the first turn's user message, proving history actually carried over
    # instead of each dispatch starting a fresh, historyless session.
    check server.requestCount == 2
    check "first turn from the thread" in server.requestBodies[1]

suite "agent dispatcher — placeholder path (no cfg/llm)":
  test "echoes input back when constructed without production args":
    var received: agent_dispatcher.AgentResult
    let cb = proc(r: agent_dispatcher.AgentResult) {.gcsafe, closure, raises: [].} =
      {.cast(gcsafe), cast(raises: []).}:
        received = r
    let dispatcher = newAgentDispatcher(cb)
    let request = AgentRequest(userInput: "echo me", channelId: "chan_5")
    waitFor dispatchAgent(dispatcher, request)
    check received.responseText == "Agent response for: echo me"
    check received.error.isNone
