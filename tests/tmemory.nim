## Tests for talos_core/memory.nim
##
## All tests use an in-memory SQLite database (:memory:) so no files are
## created on disk and tests are fully isolated.

import std/[unittest, strutils, os, times]
import talos_core/llm_client
import talos_core/memory

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeMemory(): Memory =
  newMemory(":memory:")

proc userMsg(content: string): ChatMessage =
  ChatMessage(role: crUser, content: content)

proc assistantMsg(content: string): ChatMessage =
  ChatMessage(role: crAssistant, content: content)

proc systemMsg(content: string): ChatMessage =
  ChatMessage(role: crSystem, content: content)

proc toolMsg(content, name, toolCallId: string): ChatMessage =
  ChatMessage(role: crTool, content: content, name: name, toolCallId: toolCallId)

# ---------------------------------------------------------------------------
# Suite: newSession
# ---------------------------------------------------------------------------

suite "newSession":
  test "returns a non-empty session ID":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    check sid.len > 0

  test "each call returns a unique ID":
    var m = makeMemory()
    defer: m.close()
    let s1 = m.newSession()
    let s2 = m.newSession()
    check s1 != s2

  test "session ID starts with 'sess_'":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    check sid.startsWith("sess_")

# ---------------------------------------------------------------------------
# Suite: appendMessage / getHistory
# ---------------------------------------------------------------------------

suite "appendMessage and getHistory":
  test "empty session returns empty history":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    let hist = m.getHistory(sid)
    check hist.len == 0

  test "appended messages are returned in order":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, systemMsg("you are helpful"))
    m.appendMessage(sid, userMsg("hello"))
    m.appendMessage(sid, assistantMsg("hi there"))
    let hist = m.getHistory(sid)
    check hist.len == 3
    check hist[0].role == crSystem
    check hist[0].content == "you are helpful"
    check hist[1].role == crUser
    check hist[1].content == "hello"
    check hist[2].role == crAssistant
    check hist[2].content == "hi there"

  test "tool message round-trips name and toolCallId":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, toolMsg("result text", "my_tool", "call_xyz"))
    let hist = m.getHistory(sid)
    check hist.len == 1
    check hist[0].role == crTool
    check hist[0].content == "result text"
    check hist[0].name == "my_tool"
    check hist[0].toolCallId == "call_xyz"

  test "assistant message with tool_calls round-trips":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    let tc = ToolCall(id: "call_1", name: "shell", arguments: "{\"cmd\":\"ls\"}")
    let msg = ChatMessage(
      role: crAssistant,
      content: "",
      toolCalls: @[tc],
    )
    m.appendMessage(sid, msg)
    let hist = m.getHistory(sid)
    check hist.len == 1
    check hist[0].toolCalls.len == 1
    check hist[0].toolCalls[0].id == "call_1"
    check hist[0].toolCalls[0].name == "shell"
    check hist[0].toolCalls[0].arguments == "{\"cmd\":\"ls\"}"

  test "multiple tool_calls round-trip":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    let tcs = @[
      ToolCall(id: "c1", name: "read_file", arguments: "{\"path\":\"/tmp/a\"}"),
      ToolCall(id: "c2", name: "write_file", arguments: "{\"path\":\"/tmp/b\"}"),
    ]
    let msg = ChatMessage(role: crAssistant, content: "", toolCalls: tcs)
    m.appendMessage(sid, msg)
    let hist = m.getHistory(sid)
    check hist[0].toolCalls.len == 2
    check hist[0].toolCalls[0].id == "c1"
    check hist[0].toolCalls[1].id == "c2"

  test "sessions are isolated from each other":
    var m = makeMemory()
    defer: m.close()
    let s1 = m.newSession()
    let s2 = m.newSession()
    m.appendMessage(s1, userMsg("session one"))
    m.appendMessage(s2, userMsg("session two"))
    let h1 = m.getHistory(s1)
    let h2 = m.getHistory(s2)
    check h1.len == 1
    check h1[0].content == "session one"
    check h2.len == 1
    check h2[0].content == "session two"

  test "unknown session returns empty history":
    var m = makeMemory()
    defer: m.close()
    let hist = m.getHistory("nonexistent_session_id")
    check hist.len == 0

  test "message with empty content is stored correctly":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, assistantMsg(""))
    let hist = m.getHistory(sid)
    check hist.len == 1
    check hist[0].content == ""

# ---------------------------------------------------------------------------
# Suite: getTokenUsage
# ---------------------------------------------------------------------------

suite "getTokenUsage":
  test "empty session returns zero usage":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    let usage = m.getTokenUsage(sid)
    check usage.promptTokens == 0
    check usage.completionTokens == 0
    check usage.totalTokens == 0

  test "single message token counts are returned":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, userMsg("hello"), tokensIn = 10, tokensOut = 0)
    let usage = m.getTokenUsage(sid)
    check usage.promptTokens == 10
    check usage.completionTokens == 0
    check usage.totalTokens == 10

  test "multiple messages accumulate token counts":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, userMsg("first"),     tokensIn = 5,  tokensOut = 0)
    m.appendMessage(sid, assistantMsg("resp"), tokensIn = 0,  tokensOut = 20)
    m.appendMessage(sid, userMsg("second"),    tokensIn = 8,  tokensOut = 0)
    m.appendMessage(sid, assistantMsg("ok"),   tokensIn = 0,  tokensOut = 15)
    let usage = m.getTokenUsage(sid)
    check usage.promptTokens == 13
    check usage.completionTokens == 35
    check usage.totalTokens == 48

  test "token usage is per-session":
    var m = makeMemory()
    defer: m.close()
    let s1 = m.newSession()
    let s2 = m.newSession()
    m.appendMessage(s1, userMsg("a"), tokensIn = 100, tokensOut = 50)
    m.appendMessage(s2, userMsg("b"), tokensIn = 7,   tokensOut = 3)
    let u1 = m.getTokenUsage(s1)
    let u2 = m.getTokenUsage(s2)
    check u1.totalTokens == 150
    check u2.totalTokens == 10

  test "unknown session returns zero usage":
    var m = makeMemory()
    defer: m.close()
    let usage = m.getTokenUsage("no_such_session")
    check usage.totalTokens == 0

# ---------------------------------------------------------------------------
# Suite: searchHistory (FTS5)
# ---------------------------------------------------------------------------

suite "searchHistory":
  test "empty query returns no results":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, userMsg("hello world"))
    let results = m.searchHistory("")
    check results.len == 0

  test "search with no matching content returns empty":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, userMsg("hello world"))
    let results = m.searchHistory("xyzzy_no_match_ever")
    check results.len == 0

  test "search finds a matching message":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, userMsg("the quick brown fox"))
    m.appendMessage(sid, userMsg("something completely different"))
    let results = m.searchHistory("quick")
    check results.len == 1
    check results[0].content == "the quick brown fox"

  test "search result contains correct session ID":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, userMsg("unique phrase here"))
    let results = m.searchHistory("unique")
    check results.len == 1
    check results[0].sessionId == sid

  test "search result contains correct role":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, assistantMsg("I can help with that"))
    let results = m.searchHistory("help")
    check results.len == 1
    check results[0].role == crAssistant

  test "search finds messages across multiple sessions":
    var m = makeMemory()
    defer: m.close()
    let s1 = m.newSession()
    let s2 = m.newSession()
    m.appendMessage(s1, userMsg("talos is a planet"))
    m.appendMessage(s2, userMsg("talos is also an element"))
    let results = m.searchHistory("talos")
    check results.len == 2

  test "search does not return non-matching messages":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, userMsg("apple banana cherry"))
    m.appendMessage(sid, userMsg("dog cat bird"))
    m.appendMessage(sid, userMsg("red green blue"))
    let results = m.searchHistory("banana")
    check results.len == 1
    check results[0].content == "apple banana cherry"

  test "search snippet is non-empty for a match":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, userMsg("the quick brown fox jumps over the lazy dog"))
    let results = m.searchHistory("fox")
    check results.len == 1
    check results[0].snippet.len > 0

  test "FTS5 phrase search works":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, userMsg("hello world from nim"))
    m.appendMessage(sid, userMsg("world peace is important"))
    # FTS5 phrase search uses double quotes
    let results = m.searchHistory("\"hello world\"")
    check results.len == 1
    check results[0].content == "hello world from nim"

  test "queries with FTS operator characters do not raise":
    # Ordinary text like "rm -rf" or "foo:bar" is invalid FTS5 syntax and
    # previously crashed searchHistory with a DbError. It must now degrade
    # to a literal, safe search instead of propagating.
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, userMsg("please run rm to delete the file"))
    for q in ["rm -rf", "foo:bar", "\"unterminated", "NEAR(", "*", "a AND"]:
      # Must not raise; result count is unimportant here.
      discard m.searchHistory(q)

  test "sanitized fallback still matches literal tokens":
    var m = makeMemory()
    defer: m.close()
    let sid = m.newSession()
    m.appendMessage(sid, userMsg("please run rm to delete the file"))
    m.appendMessage(sid, userMsg("nothing relevant here"))
    # "rm delete" is not valid as-is only if it were operators; here both are
    # bare terms, but the mixed-operator form "rm -delete" exercises the
    # sanitized AND fallback and should still find the message with both.
    let results = m.searchHistory("rm -delete")
    check results.len == 1
    check results[0].content == "please run rm to delete the file"

# ---------------------------------------------------------------------------
# Suite: multiple Memory instances (isolation)
# ---------------------------------------------------------------------------

suite "Memory isolation":
  test "two in-memory databases are independent":
    var m1 = makeMemory()
    var m2 = makeMemory()
    defer:
      m1.close()
      m2.close()
    let s1 = m1.newSession()
    m1.appendMessage(s1, userMsg("only in m1"))
    let s2 = m2.newSession()
    # m2 should have no messages
    let hist = m2.getHistory(s2)
    check hist.len == 0
    # m1 should have its message
    let h1 = m1.getHistory(s1)
    check h1.len == 1
    check h1[0].content == "only in m1"

# ---------------------------------------------------------------------------
# Suite: WAL mode concurrency
#
# Task 1 Phase 1b: newMemory() enables PRAGMA journal_mode=WAL and
# busy_timeout=5000 so a writer and a reader can hit the same file-backed
# database from separate threads/connections without SQLITE_BUSY. This
# only exercises anything real against a file on disk — :memory: databases
# are private per-connection, so the earlier suites can't cover this.
# ---------------------------------------------------------------------------

type
  ThreadOutcome = object
    ok: bool
    error: string

var writerChan: Channel[ThreadOutcome]
var readerChan: Channel[ThreadOutcome]

proc walWriterThread(dbPath: string) {.thread.} =
  var outcome = ThreadOutcome(ok: true)
  try:
    var m = newMemory(dbPath)
    defer: m.close()
    for i in 1 .. 50:
      let sid = m.newSession()
      m.appendMessage(sid, userMsg("writer message " & $i))
  except CatchableError as e:
    outcome.ok = false
    outcome.error = e.msg
  writerChan.send(outcome)

proc walReaderThread(dbPath: string) {.thread.} =
  var outcome = ThreadOutcome(ok: true)
  try:
    var m = newMemory(dbPath)
    defer: m.close()
    for i in 1 .. 50:
      discard m.listSessions(limit = 10)
      discard m.searchHistory("writer")
  except CatchableError as e:
    outcome.ok = false
    outcome.error = e.msg
  readerChan.send(outcome)

suite "WAL mode concurrency":
  test "concurrent writer and reader threads do not hit SQLITE_BUSY":
    let dbPath = getTempDir() / ("talos_wal_test_" & $getTime().toUnix() &
                                  "_" & $getCurrentProcessId() & ".db")
    for suffix in ["", "-wal", "-shm"]:
      try: removeFile(dbPath & suffix)
      except OSError: discard
    defer:
      for suffix in ["", "-wal", "-shm"]:
        try: removeFile(dbPath & suffix)
        except OSError: discard

    # Create the file (and schema) up front so both threads open the same
    # already-initialized database rather than racing on initSchema().
    block:
      var seed = newMemory(dbPath)
      seed.close()

    writerChan.open()
    readerChan.open()

    var writerThread: Thread[string]
    var readerThread: Thread[string]
    createThread(writerThread, walWriterThread, dbPath)
    createThread(readerThread, walReaderThread, dbPath)

    let wr = writerChan.recv()
    let rr = readerChan.recv()
    joinThread(writerThread)
    joinThread(readerThread)
    writerChan.close()
    readerChan.close()

    check wr.ok
    check rr.ok
    if not wr.ok:
      echo "writer thread error: " & wr.error
    if not rr.ok:
      echo "reader thread error: " & rr.error
