## Talos advisor role (task-16).
##
## A second agent session that watches the primary agent's own transcript
## and — after a persisted turn completes — may inject a short note into
## the *next* turn's LLM input, without ever writing its own reasoning (or
## the note itself) to the primary agent's persisted session history.
##
## Concurrency: the source report's requirement is that this "should not
## be a blocking review step." Talos's agent loop is already
## single-threaded end to end — agent_dispatcher.nim's own docstring notes
## dimscord can't be compiled with --threads:on, so even the *primary*
## agent already blocks the Discord event-loop thread during a run.
## Against that constraint, a second OS thread for the advisor wouldn't
## buy real parallelism (Memory/LLMClient haven't been audited for
## thread-safety, and the one thread that matters — the event loop — is
## still blocked either way); it would only add complexity. "Not
## blocking" is satisfied instead by running the advisor *after* the
## user already has their answer for the turn (see
## agent_dispatcher.dispatchAgent, which calls back to the surface before
## running the advisor) rather than by literal simultaneity. Revisit if
## the dimscord threading constraint ever lifts.
##
## Cadence: every persisted primary turn gets one advisor call. No
## separate cheap "is this worth reviewing" pre-filter — a reasonable
## follow-on if advisor LLM cost becomes a concern, but unnecessary
## complexity for v1.

import std/[json, strutils, tables, options]
import llm_client
import persona

type
  AdvisorSeverity* = enum
    asAside = "aside"
    asConcern = "concern"
    asBlocker = "blocker"

  AdvisorNote* = object
    turnIndex*: int
    note*: string
    severity*: AdvisorSeverity

const
  DefaultAdvisorPersonaName* = "advisor"
    ## A persona registered under this name in personas.toml is what an
    ## "advisor is configured and enabled for a session" (task-16's
    ## acceptance criteria) means in practice — no separate config
    ## surface, same convention task-17 uses for its default-routing
    ## persona.

  AdvisorProtocolPrompt* = """
Respond with ONLY one of the following — no other text:
- If there is nothing worth flagging about the assistant's latest turn,
  respond with exactly: NONE
- If there is something worth flagging (a mistake, a risk, a missed
  constraint, a better approach) respond with ONLY this JSON:
  {"note": "<one or two sentences>", "severity": "aside"|"concern"|"blocker"}
""".strip()

proc parseSeverity(s: string): AdvisorSeverity =
  case s.toLowerAscii()
  of "blocker": asBlocker
  of "concern": asConcern
  else: asAside

proc parseAdvisorResponse*(content: string; turnIndex: int = 0): Option[AdvisorNote] =
  ## Parses one advisor LLM response into an `AdvisorNote`, or `none` if
  ## the advisor said "NONE", said nothing usable, or violated the
  ## protocol (malformed JSON, missing/empty "note") — a protocol
  ## violation is treated the same as "nothing to flag" rather than as an
  ## error, since a broken advisor response must never break the primary
  ## agent's own turn.
  let trimmed = content.strip()
  if trimmed.len == 0 or trimmed.toUpperAscii() == "NONE":
    return none(AdvisorNote)
  try:
    let node = parseJson(trimmed)
    if node.kind != JObject or not node.hasKey("note") or
       node["note"].kind != JString:
      return none(AdvisorNote)
    let noteText = node["note"].getStr().strip()
    if noteText.len == 0:
      return none(AdvisorNote)
    let severity =
      if node.hasKey("severity") and node["severity"].kind == JString:
        parseSeverity(node["severity"].getStr())
      else:
        asAside
    return some(AdvisorNote(turnIndex: turnIndex, note: noteText, severity: severity))
  except CatchableError:
    return none(AdvisorNote)

proc runAdvisor*(
    advisorPersona: PersonaConfig;
    llm: LLMClient;
    transcript: seq[ChatMessage];
    turnIndex: int = 0;
): Option[AdvisorNote] =
  ## Runs one LLM call over `transcript` — the primary agent's own message
  ## history, read-only — using `advisorPersona.systemPrompt` (what the
  ## advisor should watch for) plus a fixed protocol addendum controlling
  ## the response format. The advisor's own reasoning lives only in this
  ## call's request/response; nothing here writes to any Memory, so it can
  ## never leak into the primary agent's persisted session history.
  ##
  ## Never raises: any LLM failure is treated as "nothing to flag" so an
  ## advisor outage can't take down the primary agent's turn.
  let sysPrompt =
    (if advisorPersona.systemPrompt.len > 0: advisorPersona.systemPrompt & "\n\n"
     else: "") & AdvisorProtocolPrompt
  var messages = @[ChatMessage(role: crSystem, content: sysPrompt)]
  messages.add(transcript)
  try:
    let resp = llm.chatCompletion(prompt = "", history = messages)
    return parseAdvisorResponse(resp.content, turnIndex)
  except LLMError:
    return none(AdvisorNote)

# ---------------------------------------------------------------------------
# Pending-note store
# ---------------------------------------------------------------------------
# The note is injected into the next turn's LLM input but must never be
# persisted to memory.nim (see AgentConfig.advisorNote in agent_loop.nim),
# so it can't live in the DB — it lives in an in-memory table keyed by
# session id, scoped to this process instead. A CLI `ask` one-shot (a new
# process per call) won't carry a note forward; `chat`/the TUI/the daemon
# (one long-running process per session) will, which is where advisor
# value is highest anyway (an ongoing conversation worth watching).

const MaxPendingNotes* = 256
  ## A note is deleted when its session's next turn takes it — but a
  ## session that never comes back (a Discord user who wanders off, in
  ## daemon mode) would otherwise leave its note behind forever. Cap the
  ## table and evict oldest-inserted first; a note stale enough to be
  ## evicted was for a conversation that stopped happening anyway.

var gPendingNotes: OrderedTable[string, string]

proc setPendingNote*(sessionId: string; note: string) =
  if sessionId.len == 0 or note.len == 0: return
  # Delete before re-inserting so an updated note counts as fresh in the
  # eviction order rather than keeping its original slot.
  gPendingNotes.del(sessionId)
  while gPendingNotes.len >= MaxPendingNotes:
    var oldest = ""
    for k in gPendingNotes.keys:
      oldest = k
      break
    gPendingNotes.del(oldest)
  gPendingNotes[sessionId] = note

proc takePendingNote*(sessionId: string): string =
  ## Returns and clears the pending note for `sessionId`, if any.
  if sessionId.len == 0: return ""
  if gPendingNotes.hasKey(sessionId):
    result = gPendingNotes[sessionId]
    gPendingNotes.del(sessionId)

proc clearPendingNotes*() =
  ## Test/reset helper — clears all pending notes process-wide.
  gPendingNotes.clear()
