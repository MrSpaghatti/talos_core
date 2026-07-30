## Tests for checkpoints / context pruning (task-14):
## memory.nim's checkpoint + context-override primitives, checkpoint.nim's
## LLM-backed rewindToCheckpoint, and agent_loop.nim's use of getContext
## so a collapsed range actually disappears from what the LLM is sent.

import std/[json, os, strutils, unittest]
import talos_core/agent_loop
import talos_core/checkpoint
import talos_core/llm_client
import talos_core/memory
import talos_core/testkit/mock_llm_server

proc chatBody(content: string): string =
  """{
    "id": "chatcmpl-1",
    "object": "chat.completion",
    "model": "test-model",
    "choices": [{
      "index": 0,
      "message": {"role": "assistant", "content": """ & escapeJson(content) & """},
      "finish_reason": "stop"
    }],
    "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}
  }"""

var sharedServer = startMockServer()

proc makeClient(): LLMClient =
  newLLMClient(baseUrl = baseUrlFor(sharedServer), apiKey = "test", model = "test-model")

proc userMsg(s: string): ChatMessage = ChatMessage(role: crUser, content: s)
proc asstMsg(s: string): ChatMessage = ChatMessage(role: crAssistant, content: s)

suite "memory checkpoint primitives":
  test "latestCheckpointAnchor is -1 with no checkpoints":
    var mem = newMemory()
    let sid = mem.newSession()
    check mem.latestCheckpointAnchor(sid) == -1
    mem.close()

  test "markCheckpoint on an empty session anchors at 0":
    var mem = newMemory()
    let sid = mem.newSession()
    check mem.markCheckpoint(sid) == 0
    check mem.latestCheckpointAnchor(sid) == 0
    mem.close()

  test "markCheckpoint anchors at the last message id":
    var mem = newMemory()
    let sid = mem.newSession()
    mem.appendMessage(sid, userMsg("one"))
    mem.appendMessage(sid, asstMsg("two"))
    let anchor = mem.markCheckpoint(sid)
    check anchor == mem.lastMessageId(sid)
    check mem.latestCheckpointAnchor(sid) == anchor
    mem.close()

  test "the most recent checkpoint wins":
    var mem = newMemory()
    let sid = mem.newSession()
    mem.appendMessage(sid, userMsg("one"))
    discard mem.markCheckpoint(sid)
    mem.appendMessage(sid, userMsg("two"))
    let second = mem.markCheckpoint(sid)
    check mem.latestCheckpointAnchor(sid) == second
    mem.close()

  test "getMessagesSince returns only messages after the anchor":
    var mem = newMemory()
    let sid = mem.newSession()
    mem.appendMessage(sid, userMsg("before"))
    let anchor = mem.markCheckpoint(sid)
    mem.appendMessage(sid, userMsg("after-1"))
    mem.appendMessage(sid, asstMsg("after-2"))
    let since = mem.getMessagesSince(sid, anchor)
    check since.len == 2
    check since[0].content == "after-1"
    check since[1].content == "after-2"
    mem.close()

  test "collapseRange hides the range from getContext but not getHistory":
    var mem = newMemory()
    let sid = mem.newSession()
    mem.appendMessage(sid, userMsg("keep"))
    let anchor = mem.markCheckpoint(sid)
    mem.appendMessage(sid, userMsg("exploratory-1"))
    mem.appendMessage(sid, asstMsg("exploratory-2"))
    let endId = mem.lastMessageId(sid)
    discard mem.collapseRange(sid, anchor, endId, "[checkpoint summary] tried stuff")

    let ctx = mem.getContext(sid)
    check ctx.len == 2
    check ctx[0].content == "keep"
    check ctx[1].content == "[checkpoint summary] tried stuff"

    let raw = mem.getHistory(sid)
    check raw.len == 4    # keep + 2 exploratory + summary
    var rawContents: seq[string] = @[]
    for m in raw: rawContents.add(m.content)
    check "exploratory-1" in rawContents
    check "exploratory-2" in rawContents
    mem.close()

  test "collapsed messages stay FTS-searchable":
    var mem = newMemory()
    let sid = mem.newSession()
    let anchor = mem.markCheckpoint(sid)
    mem.appendMessage(sid, userMsg("zanzibar exploration detail"))
    discard mem.collapseRange(sid, anchor, mem.lastMessageId(sid), "summary")
    let hits = mem.searchHistory("zanzibar")
    check hits.len == 1
    mem.close()

  test "collapse persists across a reopen of the same database file":
    let path = getTempDir() / "talos_tcheckpoint_persist.db"
    removeFile(path)
    var mem = newMemory(path)
    let sid = mem.newSession()
    mem.appendMessage(sid, userMsg("keep"))
    let anchor = mem.markCheckpoint(sid)
    mem.appendMessage(sid, userMsg("collapse-me"))
    discard mem.collapseRange(sid, anchor, mem.lastMessageId(sid), "summary msg")
    mem.close()

    var mem2 = newMemory(path)
    let ctx = mem2.getContext(sid)
    check ctx.len == 2
    check ctx[0].content == "keep"
    check ctx[1].content == "summary msg"
    mem2.close()
    removeFile(path)

suite "rewindToCheckpoint":
  setup:
    resetMock(sharedServer)

  test "raises when the session has no checkpoint":
    var mem = newMemory()
    let sid = mem.newSession()
    mem.appendMessage(sid, userMsg("hello"))
    expect CheckpointError:
      discard rewindToCheckpoint(mem, makeClient(), sid)
    mem.close()

  test "raises when nothing has happened since the checkpoint":
    var mem = newMemory()
    let sid = mem.newSession()
    mem.appendMessage(sid, userMsg("hello"))
    discard mem.markCheckpoint(sid)
    expect CheckpointError:
      discard rewindToCheckpoint(mem, makeClient(), sid)
    mem.close()

  test "collapses the turns since the checkpoint behind an LLM summary":
    var mem = newMemory()
    let sid = mem.newSession()
    mem.appendMessage(sid, userMsg("stable context"))
    discard mem.markCheckpoint(sid)
    mem.appendMessage(sid, userMsg("dig into the logs"))
    mem.appendMessage(sid, asstMsg("found the bug in frobnicate()"))
    sharedServer.enqueue("200 OK", chatBody("Investigated logs; bug is in frobnicate()."))
    let res = rewindToCheckpoint(mem, makeClient(), sid)
    check res.collapsed == 2
    check res.summary == "Investigated logs; bug is in frobnicate()."
    let ctx = mem.getContext(sid)
    check ctx.len == 2
    check ctx[0].content == "stable context"
    check ctx[1].content == CheckpointSummaryPrefix & res.summary
    mem.close()

  test "the summarization request contains the collapsed turns":
    var mem = newMemory()
    let sid = mem.newSession()
    discard mem.markCheckpoint(sid)
    mem.appendMessage(sid, userMsg("unique-marker-alpha"))
    mem.appendMessage(sid, asstMsg("unique-marker-beta"))
    sharedServer.enqueue("200 OK", chatBody("summary"))
    discard rewindToCheckpoint(mem, makeClient(), sid)
    let reqJson = parseJson(sharedServer.requestBodies[0])
    let sent = $reqJson["messages"]
    check sent.contains("unique-marker-alpha")
    check sent.contains("unique-marker-beta")
    mem.close()

  test "an LLM failure leaves the session untouched":
    var mem = newMemory()
    let sid = mem.newSession()
    discard mem.markCheckpoint(sid)
    mem.appendMessage(sid, userMsg("survives"))
    # 3 attempts: chatCompletion retries 5xx up to maxRetries times.
    sharedServer.enqueue("500 Internal Server Error", "{}")
    sharedServer.enqueue("500 Internal Server Error", "{}")
    sharedServer.enqueue("500 Internal Server Error", "{}")
    expect LLMError:
      discard rewindToCheckpoint(mem, makeClient(), sid)
    check mem.getContext(sid).len == 1
    check mem.getHistory(sid).len == 1
    mem.close()

suite "agent loop uses the collapsed context":
  setup:
    resetMock(sharedServer)

  test "after a rewind, the next turn's LLM request has the summary, not the raw turns":
    var mem = newMemory()
    var agentCfg = defaultAgentConfig()

    # Turn 1: normal exchange.
    sharedServer.enqueue("200 OK", chatBody("first answer"))
    let first = runAgentLoop(agentCfg, makeClient(), nil, mem, "first question")
    let sid = first.sessionId

    # Checkpoint, then an exploratory turn we'll collapse.
    discard mem.markCheckpoint(sid)
    sharedServer.enqueue("200 OK", chatBody("noisy exploration answer"))
    discard runAgentLoop(agentCfg, makeClient(), nil, mem, "noisy exploration question",
      resumeSessionId = sid)

    # Rewind (one summarization call).
    sharedServer.enqueue("200 OK", chatBody("condensed: explored, found nothing"))
    discard rewindToCheckpoint(mem, makeClient(), sid)

    # Next real turn: its request must contain the summary and neither
    # side of the collapsed exchange.
    sharedServer.enqueue("200 OK", chatBody("post-rewind answer"))
    discard runAgentLoop(agentCfg, makeClient(), nil, mem, "post-rewind question",
      resumeSessionId = sid)
    let reqJson = parseJson(sharedServer.requestBodies[^1])
    let sent = $reqJson["messages"]
    check sent.contains("condensed: explored, found nothing")
    check sent.contains("first question")          # pre-checkpoint context kept
    check not sent.contains("noisy exploration question")
    check not sent.contains("noisy exploration answer")
    mem.close()
