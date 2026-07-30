## Tests for talos_core/advisor.nim (task-16).

import std/[json, options, strutils, unittest]
import talos_core/advisor
import talos_core/llm_client
import talos_core/persona
import talos_core/testkit/mock_llm_server

proc successBody(content: string): string =
  """
{
  "id": "chatcmpl-1",
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

var sharedServer = startMockServer()

proc makeClient(): LLMClient =
  newLLMClient(baseUrl = baseUrlFor(sharedServer), apiKey = "test", model = "advisor-model")

let samplePersona = PersonaConfig(
  name: "advisor",
  systemPrompt: "Watch for correctness mistakes.",
)

let sampleTranscript = @[
  ChatMessage(role: crUser, content: "delete all the temp files"),
  ChatMessage(role: crAssistant, content: "Running rm -rf /tmp/*"),
]

# ---------------------------------------------------------------------------
# Suite: parseAdvisorResponse
# ---------------------------------------------------------------------------

suite "parseAdvisorResponse":
  test "\"NONE\" produces no note":
    check parseAdvisorResponse("NONE").isNone

  test "empty content produces no note":
    check parseAdvisorResponse("").isNone

  test "whitespace-only content produces no note":
    check parseAdvisorResponse("   \n  ").isNone

  test "\"none\" is matched case-insensitively":
    check parseAdvisorResponse("none").isNone

  test "valid JSON with a note is parsed":
    let note = parseAdvisorResponse("""{"note": "double-check that path", "severity": "concern"}""")
    check note.isSome
    check note.get().note == "double-check that path"
    check note.get().severity == asConcern

  test "missing severity defaults to aside":
    let note = parseAdvisorResponse("""{"note": "minor nit"}""")
    check note.isSome
    check note.get().severity == asAside

  test "unrecognized severity value falls back to aside":
    let note = parseAdvisorResponse("""{"note": "x", "severity": "urgent"}""")
    check note.isSome
    check note.get().severity == asAside

  test "\"blocker\" severity is parsed":
    let note = parseAdvisorResponse("""{"note": "this will delete user data", "severity": "blocker"}""")
    check note.isSome
    check note.get().severity == asBlocker

  test "empty note field produces no note":
    check parseAdvisorResponse("""{"note": ""}""").isNone

  test "malformed JSON is treated as no note, not an error":
    check parseAdvisorResponse("{not valid json").isNone

  test "JSON missing the note field produces no note":
    check parseAdvisorResponse("""{"severity": "blocker"}""").isNone

  test "turnIndex is threaded through":
    let note = parseAdvisorResponse("""{"note": "x"}""", turnIndex = 7)
    check note.get().turnIndex == 7

# ---------------------------------------------------------------------------
# Suite: runAdvisor
# ---------------------------------------------------------------------------

suite "runAdvisor":
  setup:
    resetMock(sharedServer)

  test "a flagged response produces an AdvisorNote":
    sharedServer.enqueue("200 OK", successBody("""{"note": "rm -rf /tmp/* is destructive, confirm first", "severity": "concern"}"""))
    let result = runAdvisor(samplePersona, makeClient(), sampleTranscript)
    check result.isSome
    check result.get().note.contains("destructive")

  test "a \"NONE\" response produces no note":
    sharedServer.enqueue("200 OK", successBody("NONE"))
    let result = runAdvisor(samplePersona, makeClient(), sampleTranscript)
    check result.isNone

  test "the advisor's system prompt combines the persona prompt with the protocol addendum":
    sharedServer.enqueue("200 OK", successBody("NONE"))
    discard runAdvisor(samplePersona, makeClient(), sampleTranscript)
    let reqJson = parseJson(sharedServer.requestBodies[0])
    let sysContent = reqJson["messages"][0]["content"].getStr()
    check sysContent.contains("Watch for correctness mistakes")
    check sysContent.contains("NONE")

  test "the full transcript is sent to the advisor":
    sharedServer.enqueue("200 OK", successBody("NONE"))
    discard runAdvisor(samplePersona, makeClient(), sampleTranscript)
    let reqJson = parseJson(sharedServer.requestBodies[0])
    var sawUserMsg = false
    for m in reqJson["messages"]:
      if m["content"].getStr("").contains("delete all the temp files"):
        sawUserMsg = true
    check sawUserMsg

  test "an LLM failure is treated as no note, not an exception":
    sharedServer.enqueue("500 Internal Server Error", """{"error": {"message": "boom"}}""")
    let result = runAdvisor(samplePersona, makeClient(), sampleTranscript)
    check result.isNone

# ---------------------------------------------------------------------------
# Suite: pending-note store
# ---------------------------------------------------------------------------

suite "pending-note store":
  setup:
    clearPendingNotes()

  test "a note set for a session is returned once and then cleared":
    setPendingNote("session-1", "watch out")
    check takePendingNote("session-1") == "watch out"
    check takePendingNote("session-1") == ""

  test "an unset session returns empty":
    check takePendingNote("nonexistent") == ""

  test "sessions are isolated from each other":
    setPendingNote("a", "note-a")
    setPendingNote("b", "note-b")
    check takePendingNote("a") == "note-a"
    check takePendingNote("b") == "note-b"

  test "setPendingNote with an empty session id is a no-op":
    setPendingNote("", "should not be stored")
    check takePendingNote("") == ""

  test "clearPendingNotes clears everything":
    setPendingNote("x", "1")
    setPendingNote("y", "2")
    clearPendingNotes()
    check takePendingNote("x") == ""
    check takePendingNote("y") == ""

  test "the store is capped: oldest note is evicted at MaxPendingNotes":
    for i in 0 ..< MaxPendingNotes:
      setPendingNote("session-" & $i, "note-" & $i)
    # One past the cap evicts the oldest-inserted session, nothing else.
    setPendingNote("session-overflow", "note-overflow")
    check takePendingNote("session-0") == ""
    check takePendingNote("session-1") == "note-1"
    check takePendingNote("session-overflow") == "note-overflow"

  test "re-setting a session's note refreshes its eviction slot":
    setPendingNote("keep-me", "old")
    for i in 0 ..< MaxPendingNotes - 1:
      setPendingNote("filler-" & $i, "x")
    # keep-me is now the oldest; updating it should make it the newest,
    # so the next overflow evicts filler-0 instead.
    setPendingNote("keep-me", "new")
    setPendingNote("one-more", "y")
    check takePendingNote("keep-me") == "new"
    check takePendingNote("filler-0") == ""
