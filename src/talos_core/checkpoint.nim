## Talos checkpoints (task-14): context pruning with a report.
##
## `markCheckpoint` (memory.nim) marks a point in a session's message log.
## `rewindToCheckpoint` here collapses everything after the most recent
## checkpoint into one compact summary produced by a single LLM call:
##
##   1. The turns since the checkpoint are summarized (one chatCompletion,
##      no tools).
##   2. The summary is appended to the session as a crSystem message and a
##      context override is recorded (memory.collapseRange), so the *next*
##      turn's context window — built via memory.getContext by
##      agent_loop.nim — contains the summary instead of the raw turns.
##   3. Nothing is deleted: getHistory()/searchHistory() still return the
##      raw turns, and the summary message is itself a normal message row
##      (FTS-indexed, embeddable like any other).
##
## The collapse is persistent (a context_overrides row in SQLite), so
## resuming the session later — same process or not — keeps the pruned
## view. This is the "persistent representation" option from
## plans/task-14-checkpoints.md, chosen because session resume
## (resumeSessionId, cross-surface aliases) is actively used.

import std/strutils
import llm_client
import memory

const
  CheckpointSummaryPrefix* = "[checkpoint summary] "
    ## Prepended to the stored summary message so both the model and a
    ## human reading `history` can tell it apart from ordinary turns.

  MaxSummaryInputChars = 60_000
    ## Hard cap on how much rendered transcript is fed to the summary
    ## call — enough for any realistic rewind span while keeping the
    ## request bounded if a tool result was enormous.

type
  CheckpointError* = object of CatchableError
    ## Raised when a rewind cannot proceed (no checkpoint set, or nothing
    ## after it to collapse).

  RewindResult* = object
    collapsed*: int        ## number of raw messages hidden behind the summary
    summaryMsgId*: int64   ## row id of the stored summary message
    summary*: string       ## the summary text (without the prefix)

proc renderForSummary(msgs: seq[ChatMessage]): string =
  ## Flattens messages into a plain-text transcript for the summary call.
  var parts: seq[string] = @[]
  for m in msgs:
    case m.role
    of crSystem:
      parts.add("[system] " & m.content)
    of crUser:
      parts.add("[user] " & m.content)
    of crAssistant:
      if m.content.len > 0:
        parts.add("[assistant] " & m.content)
      for tc in m.toolCalls:
        parts.add("[assistant tool-call] " & tc.name & "(" & tc.arguments & ")")
    of crTool:
      parts.add("[tool " & m.name & "] " & m.content)
  result = parts.join("\n")
  if result.len > MaxSummaryInputChars:
    result = result[0 ..< MaxSummaryInputChars] & "\n[... truncated for summarization]"

proc rewindToCheckpoint*(
    mem: var Memory;
    llm: LLMClient;
    sessionId: string;
): RewindResult =
  ## Collapses everything after the session's most recent checkpoint into
  ## one summary message. Raises CheckpointError if the session has no
  ## checkpoint or nothing has happened since it. LLM failures propagate
  ## as LLMError — in that case nothing is written, so the session is
  ## untouched and the rewind can simply be retried.
  let anchor = mem.latestCheckpointAnchor(sessionId)
  if anchor < 0:
    raise newException(CheckpointError,
      "no checkpoint set for session " & sessionId)
  let since = mem.getMessagesSince(sessionId, anchor)
  if since.len == 0:
    raise newException(CheckpointError,
      "nothing to rewind: no messages since the last checkpoint")
  let endId = mem.lastMessageId(sessionId)

  let prompt = """
Summarize the following conversation excerpt into a compact report that
preserves everything a continuing assistant needs: decisions made, facts
discovered, files or resources touched, errors hit and how they resolved,
and anything still unresolved. Omit pleasantries and dead ends that led
nowhere. Write plain prose, no preamble.

Excerpt:
""" & renderForSummary(since)

  let resp = llm.chatCompletion(prompt)
  let summary = resp.content.strip()

  result.summary = summary
  result.collapsed = since.len
  result.summaryMsgId = mem.collapseRange(
    sessionId, anchor, endId, CheckpointSummaryPrefix & summary)
