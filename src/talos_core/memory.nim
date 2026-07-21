## Talos SQLite memory module.
##
## Persistent conversation memory backed by SQLite with FTS5 full-text search.
##
## Schema:
##   sessions  — one row per conversation session
##   messages  — one row per chat message, linked to a session
##   messages_fts — FTS5 virtual table mirroring messages.content
##
## Features:
##   - newSession(): creates a new session, returns its ID
##   - appendMessage(): stores a ChatMessage with token counts
##   - getHistory(): retrieves all messages for a session as seq[ChatMessage]
##   - searchHistory(): full-text search across all message content
##   - getTokenUsage(): aggregated token stats for a session
##
## WAL mode is enabled for better concurrent read performance.
## Tool calls and tool results are stored as JSON strings.
##
## Out of scope (deferred):
##   - Vector / embedding search
##   - Memory summarization / compaction
##   - Cross-session retrieval

import db_connector/db_sqlite
import std/[json, strutils, times]
import talos_core/llm_client

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  Memory* = object
    ## Wraps a SQLite connection and exposes the memory API.
    db: DbConn

  SearchResult* = object
    ## A single full-text search hit.
    sessionId*: string
    messageId*: int64
    role*: ChatRole
    content*: string
    snippet*: string          ## FTS5 snippet (may equal content for short msgs)
    createdAt*: string

  SessionSummary* = object
    ## Lightweight session metadata for listing.
    id*: string
    createdAt*: string
    updatedAt*: string
    messageCount*: int

  MemoryError* = object of CatchableError
    ## Raised on unrecoverable database errors.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc roleToStr(r: ChatRole): string =
  case r
  of crSystem:    "system"
  of crUser:      "user"
  of crAssistant: "assistant"
  of crTool:      "tool"

proc strToRole(s: string): ChatRole =
  case s.toLowerAscii()
  of "system":    crSystem
  of "user":      crUser
  of "assistant": crAssistant
  of "tool":      crTool
  else:           crUser

proc toolCallsToJson(tcs: seq[ToolCall]): string =
  ## Serialises a seq[ToolCall] to a compact JSON array string.
  if tcs.len == 0:
    return "[]"
  var arr = newJArray()
  for tc in tcs:
    var obj = newJObject()
    obj["id"]        = %tc.id
    obj["name"]      = %tc.name
    obj["arguments"] = %tc.arguments
    arr.add(obj)
  return $arr

proc jsonToToolCalls(s: string): seq[ToolCall] =
  ## Deserialises a JSON array string back to seq[ToolCall].
  result = @[]
  if s.len == 0 or s == "[]":
    return
  try:
    let node = parseJson(s)
    if node.kind != JArray:
      return
    for item in node:
      if item.kind != JObject:
        continue
      var tc = ToolCall()
      if item.hasKey("id") and item["id"].kind == JString:
        tc.id = item["id"].getStr()
      if item.hasKey("name") and item["name"].kind == JString:
        tc.name = item["name"].getStr()
      if item.hasKey("arguments") and item["arguments"].kind == JString:
        tc.arguments = item["arguments"].getStr()
      result.add(tc)
  except CatchableError:
    discard

proc nowIso(): string =
  ## Returns the current UTC time as an ISO 8601 string.
  let t = now().utc
  return t.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc generateSessionId(): string =
  ## Generates a session ID based on the current UTC timestamp plus a
  ## nanosecond component for uniqueness.
  let t = now().utc
  return "sess_" & t.format("yyyyMMdd'T'HHmmss") & "_" &
         $getTime().nanosecond

# ---------------------------------------------------------------------------
# Schema initialisation
# ---------------------------------------------------------------------------

proc initSchema(db: DbConn) =
  ## Creates tables and FTS5 virtual table if they do not already exist.
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS sessions (
      id          TEXT PRIMARY KEY,
      created_at  TEXT NOT NULL,
      updated_at  TEXT NOT NULL,
      metadata    TEXT NOT NULL DEFAULT '{}'
    )
  """)

  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS messages (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id    TEXT    NOT NULL REFERENCES sessions(id),
      role          TEXT    NOT NULL,
      content       TEXT    NOT NULL DEFAULT '',
      name          TEXT    NOT NULL DEFAULT '',
      tool_call_id  TEXT    NOT NULL DEFAULT '',
      tool_calls    TEXT    NOT NULL DEFAULT '[]',
      tool_results  TEXT    NOT NULL DEFAULT '[]',
      tokens_in     INTEGER NOT NULL DEFAULT 0,
      tokens_out    INTEGER NOT NULL DEFAULT 0,
      created_at    TEXT    NOT NULL
    )
  """)

  # FTS5 virtual table — content= makes it a "content table" backed by messages.
  # rowid links to messages.id for efficient joins.
  db.exec(sql"""
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
    USING fts5(
      content,
      content='messages',
      content_rowid='id'
    )
  """)

  # Triggers to keep FTS index in sync with the messages table.
  db.exec(sql"""
    CREATE TRIGGER IF NOT EXISTS messages_ai
    AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(rowid, content)
      VALUES (new.id, new.content);
    END
  """)

  db.exec(sql"""
    CREATE TRIGGER IF NOT EXISTS messages_ad
    AFTER DELETE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, content)
      VALUES ('delete', old.id, old.content);
    END
  """)

  db.exec(sql"""
    CREATE TRIGGER IF NOT EXISTS messages_au
    AFTER UPDATE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, content)
      VALUES ('delete', old.id, old.content);
      INSERT INTO messages_fts(rowid, content)
      VALUES (new.id, new.content);
    END
  """)

# ---------------------------------------------------------------------------
# Constructor / destructor
# ---------------------------------------------------------------------------

proc newMemory*(path: string = ":memory:"): Memory =
  ## Opens (or creates) a SQLite database at `path`.
  ## Pass ":memory:" for an in-memory database (useful for tests).
  let db = open(path, "", "", "")
  db.exec(sql"PRAGMA journal_mode=WAL")
  db.exec(sql"PRAGMA busy_timeout=5000")
  db.exec(sql"PRAGMA foreign_keys=ON")
  initSchema(db)
  result = Memory(db: db)

proc close*(m: var Memory) =
  ## Closes the underlying database connection.
  m.db.close()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc newSession*(m: Memory; metadata: string = "{}"): string =
  ## Creates a new session row and returns its ID.
  let id = generateSessionId()
  let ts = nowIso()
  m.db.exec(sql"""
    INSERT INTO sessions (id, created_at, updated_at, metadata)
    VALUES (?, ?, ?, ?)
  """, id, ts, ts, metadata)
  return id

proc hasSession*(m: Memory; sessionId: string): bool =
  ## True if a session row with this ID already exists.
  let row = m.db.getRow(sql"SELECT id FROM sessions WHERE id = ?", sessionId)
  row[0].len > 0

proc ensureSession*(m: Memory; sessionId: string; metadata: string = "{}") =
  ## Creates a session row with the given ID if one does not already exist.
  ## Used to resume a caller-supplied session ID (e.g. a Discord thread's
  ## mapped session) that may or may not have a row yet — the first turn in
  ## a thread creates it, later turns reuse it.
  if not m.hasSession(sessionId):
    let ts = nowIso()
    m.db.exec(sql"""
      INSERT INTO sessions (id, created_at, updated_at, metadata)
      VALUES (?, ?, ?, ?)
    """, sessionId, ts, ts, metadata)

proc appendMessage*(
    m: Memory;
    sessionId: string;
    message: ChatMessage;
    tokensIn: int = 0;
    tokensOut: int = 0;
) =
  ## Appends a ChatMessage to the given session.
  ## Updates sessions.updated_at as a side effect.
  let ts = nowIso()
  let tcJson = toolCallsToJson(message.toolCalls)
  m.db.exec(sql"""
    INSERT INTO messages
      (session_id, role, content, name, tool_call_id,
       tool_calls, tool_results, tokens_in, tokens_out, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  """,
    sessionId,
    roleToStr(message.role),
    message.content,
    message.name,
    message.toolCallId,
    tcJson,
    "[]",          ## tool_results reserved for future use
    $tokensIn,
    $tokensOut,
    ts,
  )
  m.db.exec(sql"""
    UPDATE sessions SET updated_at = ? WHERE id = ?
  """, ts, sessionId)

proc getHistory*(m: Memory; sessionId: string): seq[ChatMessage] =
  ## Returns all messages for `sessionId` in insertion order.
  result = @[]
  for row in m.db.fastRows(sql"""
    SELECT role, content, name, tool_call_id, tool_calls
    FROM messages
    WHERE session_id = ?
    ORDER BY id ASC
  """, sessionId):
    let msg = ChatMessage(
      role:       strToRole(row[0]),
      content:    row[1],
      name:       row[2],
      toolCallId: row[3],
      toolCalls:  jsonToToolCalls(row[4]),
    )
    result.add(msg)

proc sanitizeFtsQuery(query: string): string =
  ## Rewrites an arbitrary search string into a valid FTS5 query by wrapping
  ## each whitespace-delimited token as a quoted string literal (embedded
  ## double-quotes are doubled per FTS5 rules) and joining them with a space,
  ## which FTS5 treats as an implicit AND. This makes inputs that contain FTS5
  ## operators or punctuation (e.g. "rm -rf", "foo:bar", a lone quote) safe to
  ## match literally instead of raising a syntax error.
  var parts: seq[string] = @[]
  for tok in query.splitWhitespace():
    parts.add("\"" & tok.replace("\"", "\"\"") & "\"")
  result = parts.join(" ")

proc runFtsSearch(m: Memory; matchExpr: string): seq[SearchResult] =
  result = @[]
  for row in m.db.fastRows(sql"""
    SELECT m.session_id,
           m.id,
           m.role,
           m.content,
           snippet(messages_fts, 0, '[', ']', '...', 20),
           m.created_at
    FROM messages_fts
    JOIN messages m ON m.id = messages_fts.rowid
    WHERE messages_fts MATCH ?
    ORDER BY rank
  """, matchExpr):
    result.add(SearchResult(
      sessionId: row[0],
      messageId: parseBiggestInt(row[1]),
      role:      strToRole(row[2]),
      content:   row[3],
      snippet:   row[4],
      createdAt: row[5],
    ))

proc searchHistory*(m: Memory; query: string): seq[SearchResult] =
  ## Full-text searches all message content using FTS5.
  ## Returns matching rows ordered by relevance (FTS5 rank).
  ##
  ## The raw query is tried first so intentional FTS5 syntax (phrase quotes,
  ## boolean operators) keeps working. If that raises a syntax error — which
  ## ordinary text such as "rm -rf" or "foo:bar" does — it is retried as a
  ## sanitized literal query. A still-invalid query yields no results rather
  ## than propagating a DbError to the caller.
  if query.len == 0:
    return @[]
  try:
    return runFtsSearch(m, query)
  except DbError:
    let sanitized = sanitizeFtsQuery(query)
    if sanitized.len == 0:
      return @[]
    try:
      return runFtsSearch(m, sanitized)
    except DbError:
      return @[]

proc listSessions*(m: Memory; limit: int = 50): seq[SessionSummary] =
  ## Returns the most recently updated sessions, up to `limit`.
  result = @[]
  for row in m.db.fastRows(sql"""
    SELECT s.id, s.created_at, s.updated_at,
           (SELECT COUNT(*) FROM messages ms WHERE ms.session_id = s.id)
    FROM sessions s
    ORDER BY s.updated_at DESC
    LIMIT ?
  """, $limit):
    result.add(SessionSummary(
      id: row[0],
      createdAt: row[1],
      updatedAt: row[2],
      messageCount: parseInt(row[3]),
    ))

proc getTokenUsage*(m: Memory; sessionId: string): TokenUsage =
  ## Returns aggregated token counts for all messages in `sessionId`.
  let row = m.db.getRow(sql"""
    SELECT COALESCE(SUM(tokens_in), 0),
           COALESCE(SUM(tokens_out), 0),
           COALESCE(SUM(tokens_in + tokens_out), 0)
    FROM messages
    WHERE session_id = ?
  """, sessionId)
  result = TokenUsage(
    promptTokens:     parseInt(row[0]),
    completionTokens: parseInt(row[1]),
    totalTokens:      parseInt(row[2]),
  )
