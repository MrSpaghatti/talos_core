## Tests for talos_core/thread_mapping.nim
##
## All tests use an in-memory SQLite database (:memory:) so no files are
## created on disk and tests are fully isolated.

import std/[unittest, options, os]
import db_connector/db_sqlite
import talos_core/thread_mapping

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc openTestDb(): DbConn =
  let db = open(":memory:", "", "", "")
  db.exec(sql"PRAGMA journal_mode=WAL")
  db.exec(sql"PRAGMA foreign_keys=ON")
  initThreadMappingSchema(db)
  return db

# ---------------------------------------------------------------------------
# Suite: initThreadMappingSchema
# ---------------------------------------------------------------------------

suite "initThreadMappingSchema":
  test "creates discord_threads table without error":
    let db = openTestDb()
    defer: db.close()
    # If we got here, schema creation succeeded
    let rows = db.getAllRows(sql"SELECT name FROM sqlite_master WHERE type='table' AND name='discord_threads'")
    check rows.len == 1

  test "idempotent — calling twice does not error":
    let db = openTestDb()
    defer: db.close()
    initThreadMappingSchema(db)  # second call should be safe
    let rows = db.getAllRows(sql"SELECT name FROM sqlite_master WHERE type='table' AND name='discord_threads'")
    check rows.len == 1

# ---------------------------------------------------------------------------
# Suite: setThreadMapping / getSessionForThread
# ---------------------------------------------------------------------------

suite "setThreadMapping and getSessionForThread":
  test "set and retrieve session ID for a thread":
    let db = openTestDb()
    defer: db.close()
    setThreadMapping(db, "thread_123", "sess_abc", "channel_456", "guild_789")
    let result = getSessionForThread(db, "thread_123")
    check result.isSome()
    check result.get() == "sess_abc"

  test "getSessionForThread returns None for unknown thread":
    let db = openTestDb()
    defer: db.close()
    let result = getSessionForThread(db, "nonexistent_thread")
    check result.isNone()

  test "setThreadMapping upserts — updating an existing mapping":
    let db = openTestDb()
    defer: db.close()
    setThreadMapping(db, "thread_123", "sess_old", "channel_456", "guild_789")
    setThreadMapping(db, "thread_123", "sess_new", "channel_456", "guild_789")
    let result = getSessionForThread(db, "thread_123")
    check result.isSome()
    check result.get() == "sess_new"

  test "multiple threads map to different sessions":
    let db = openTestDb()
    defer: db.close()
    setThreadMapping(db, "thread_1", "sess_a", "channel_x", "guild_g")
    setThreadMapping(db, "thread_2", "sess_b", "channel_x", "guild_g")
    check getSessionForThread(db, "thread_1").get() == "sess_a"
    check getSessionForThread(db, "thread_2").get() == "sess_b"

# ---------------------------------------------------------------------------
# Suite: archiveThread
# ---------------------------------------------------------------------------

suite "archiveThread":
  test "archiveThread marks a thread as archived":
    let db = openTestDb()
    defer: db.close()
    setThreadMapping(db, "thread_123", "sess_abc", "channel_456", "guild_789")
    archiveThread(db, "thread_123")
    let row = db.getRow(sql"SELECT is_archived FROM discord_threads WHERE thread_id = ?", "thread_123")
    check row[0] == "1"

  test "archiveThread on nonexistent thread does not error":
    let db = openTestDb()
    defer: db.close()
    archiveThread(db, "nonexistent_thread")  # should not raise

  test "archived thread still returns session via getSessionForThread":
    let db = openTestDb()
    defer: db.close()
    setThreadMapping(db, "thread_123", "sess_abc", "channel_456", "guild_789")
    archiveThread(db, "thread_123")
    let result = getSessionForThread(db, "thread_123")
    check result.isSome()
    check result.get() == "sess_abc"

# ---------------------------------------------------------------------------
# Suite: getLatestSessionForChannel
# ---------------------------------------------------------------------------

suite "getLatestSessionForChannel":
  test "returns the most recent session for a channel":
    let db = openTestDb()
    defer: db.close()
    setThreadMapping(db, "thread_1", "sess_first", "channel_x", "guild_g")
    sleep(1100)  # ensure different second-level timestamps
    setThreadMapping(db, "thread_2", "sess_second", "channel_x", "guild_g")
    let result = getLatestSessionForChannel(db, "channel_x")
    check result.isSome()
    check result.get() == "sess_second"

  test "returns None for a channel with no threads":
    let db = openTestDb()
    defer: db.close()
    let result = getLatestSessionForChannel(db, "empty_channel")
    check result.isNone()

  test "skips archived threads by default":
    let db = openTestDb()
    defer: db.close()
    setThreadMapping(db, "thread_1", "sess_archived", "channel_x", "guild_g")
    archiveThread(db, "thread_1")
    setThreadMapping(db, "thread_2", "sess_active", "channel_x", "guild_g")
    let result = getLatestSessionForChannel(db, "channel_x")
    check result.isSome()
    check result.get() == "sess_active"

  test "returns archived session when all threads are archived":
    let db = openTestDb()
    defer: db.close()
    setThreadMapping(db, "thread_1", "sess_archived", "channel_x", "guild_g")
    archiveThread(db, "thread_1")
    let result = getLatestSessionForChannel(db, "channel_x")
    check result.isSome()
    check result.get() == "sess_archived"

  test "different channels are isolated":
    let db = openTestDb()
    defer: db.close()
    setThreadMapping(db, "thread_1", "sess_a", "channel_x", "guild_g")
    setThreadMapping(db, "thread_2", "sess_b", "channel_y", "guild_g")
    check getLatestSessionForChannel(db, "channel_x").get() == "sess_a"
    check getLatestSessionForChannel(db, "channel_y").get() == "sess_b"

# ---------------------------------------------------------------------------
# Suite: last_active_at updates
# ---------------------------------------------------------------------------

suite "last_active_at tracking":
  test "setThreadMapping sets created_at and last_active_at":
    let db = openTestDb()
    defer: db.close()
    setThreadMapping(db, "thread_1", "sess_a", "channel_x", "guild_g")
    let row = db.getRow(sql"SELECT created_at, last_active_at FROM discord_threads WHERE thread_id = ?", "thread_1")
    check row[0].len > 0
    check row[1].len > 0

  test "upsert updates last_active_at":
    let db = openTestDb()
    defer: db.close()
    setThreadMapping(db, "thread_1", "sess_old", "channel_x", "guild_g")
    let row1 = db.getRow(sql"SELECT last_active_at FROM discord_threads WHERE thread_id = ?", "thread_1")
    sleep(1100)  # ensure a different second-level timestamp
    setThreadMapping(db, "thread_1", "sess_new", "channel_x", "guild_g")
    let row2 = db.getRow(sql"SELECT last_active_at FROM discord_threads WHERE thread_id = ?", "thread_1")
    # Strictly newer, not just "not older" — a bug that forgot to bump
    # last_active_at on upsert would still pass a `>=` check.
    check row2[0] > row1[0]