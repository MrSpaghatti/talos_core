## Talos thread mapping module.
##
## Maps Discord thread IDs to agent session IDs in SQLite.
##
## Schema:
##   discord_threads — one row per Discord thread, linking to a session
##
## Features:
##   - initThreadMappingSchema(): creates the discord_threads table
##   - setThreadMapping(): upsert a thread→session mapping
##   - getSessionForThread(): look up session ID by thread ID
##   - archiveThread(): mark a thread as archived
##   - getLatestSessionForChannel(): find the most recent session for a channel
##
## WAL mode is enabled for better concurrent read performance.
## Each thread should open its own DB connection for thread safety.

import db_connector/db_sqlite
import std/options
import std/times

# ---------------------------------------------------------------------------
# Schema initialisation
# ---------------------------------------------------------------------------

proc initThreadMappingSchema*(db: DbConn) =
  ## Creates the discord_threads table if it does not already exist.
  ## Safe to call multiple times (idempotent).
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS discord_threads (
      thread_id       TEXT PRIMARY KEY,
      session_id      TEXT NOT NULL,
      channel_id      TEXT NOT NULL,
      guild_id        TEXT NOT NULL DEFAULT '',
      created_at      TEXT NOT NULL,
      last_active_at  TEXT NOT NULL,
      is_archived     INTEGER NOT NULL DEFAULT 0
    )
  """)

  db.exec(sql"""
    CREATE INDEX IF NOT EXISTS idx_discord_threads_channel
    ON discord_threads(channel_id, last_active_at DESC)
  """)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc nowIso(): string =
  ## Returns the current UTC time as an ISO 8601 string.
  let t = now().utc
  return t.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc setThreadMapping*(db: DbConn; threadId, sessionId, channelId, guildId: string) =
  ## Upserts a thread→session mapping. If the thread already exists, updates
  ## the session_id, channel_id, guild_id, and last_active_at.
  let ts = nowIso()
  # Use INSERT OR REPLACE to handle upsert
  db.exec(sql"""
    INSERT INTO discord_threads (thread_id, session_id, channel_id, guild_id, created_at, last_active_at, is_archived)
    VALUES (?, ?, ?, ?, ?, ?, 0)
    ON CONFLICT(thread_id) DO UPDATE SET
      session_id = excluded.session_id,
      channel_id = excluded.channel_id,
      guild_id = excluded.guild_id,
      last_active_at = excluded.last_active_at,
      is_archived = 0
  """, threadId, sessionId, channelId, guildId, ts, ts)

proc getSessionForThread*(db: DbConn; threadId: string): Option[string] =
  ## Returns the session ID associated with the given thread ID,
  ## or None if the thread is not found.
  let row = db.getRow(sql"""
    SELECT session_id FROM discord_threads WHERE thread_id = ?
  """, threadId)
  if row[0].len == 0:
    return none[string]()
  return some(row[0])

proc archiveThread*(db: DbConn; threadId: string) =
  ## Marks a thread as archived. No-op if the thread does not exist.
  let ts = nowIso()
  db.exec(sql"""
    UPDATE discord_threads SET is_archived = 1, last_active_at = ?
    WHERE thread_id = ?
  """, ts, threadId)

proc getLatestSessionForChannel*(db: DbConn; channelId: string): Option[string] =
  ## Returns the session ID of the most recently active thread in the given
  ## channel. Prefers non-archived threads. If all threads are archived,
  ## returns the most recently active archived one.
  ## Returns None if no threads exist for the channel.
  # Try non-archived first
  let row = db.getRow(sql"""
    SELECT session_id FROM discord_threads
    WHERE channel_id = ? AND is_archived = 0
    ORDER BY last_active_at DESC
    LIMIT 1
  """, channelId)
  if row[0].len > 0:
    return some(row[0])
  # Fall back to archived
  let archivedRow = db.getRow(sql"""
    SELECT session_id FROM discord_threads
    WHERE channel_id = ?
    ORDER BY last_active_at DESC
    LIMIT 1
  """, channelId)
  if archivedRow[0].len > 0:
    return some(archivedRow[0])
  return none[string]()