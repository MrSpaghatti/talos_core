import std/[asyncdispatch, strutils, unittest, options]
import db_connector/db_sqlite
import talos_core/discord
import talos_core/discord_mocks
import talos_core/discord_types
import talos_core/agent_dispatcher
import talos_core/thread_mapping

proc openTestDb(): DbConn =
  let db = open(":memory:", "", "", "")
  initThreadMappingSchema(db)
  return db

proc makeConfig(): DiscordConfig =
  result = defaultDiscordConfig()
  result.users.allow = @["user1"]

proc makeDispatcher(): AgentDispatcher =
  newAgentDispatcher(proc(r: AgentResult) = discard)

suite "thread reconnection":
  test "mention in channel with archived thread creates new thread and reuses old session":
    let db = openTestDb()
    defer: db.close()
    let api = newMockDiscordApi()
    let bot = newDiscordBot(
      sendMessage = mockSendFn(api),
      triggerTyping = mockTypingFn(api),
      createThread = mockCreateThreadFn(api),
      archiveThread = mockArchiveThreadFn(api),
      db = db,
      config = makeConfig(),
      dispatcher = makeDispatcher(),
      shard = newMockShard("bot"),
    )

    setThreadMapping(db, "old_thread", "sess_old123", "chan1", "guild1")
    archiveThread(db, "old_thread")

    let msg = Message(
      id: "msg_1",
      author: MockUser(id: "user1", username: "user1", bot: false),
      content: "<@bot> hello",
      channel_id: "chan1",
      guild_id: some("guild1"),
      mention_users: @[MockUser(id: "bot", username: "bot", bot: false)],
    )

    waitFor bot.onMessageCreate(msg)

    check api.calls.len >= 3
    check api.calls[0].kind == mockCreateThread
    check api.calls[0].name == "Talos-sess_old"
    check api.calls[1].kind == mockSendMessage
    check api.calls[1].content == "Continuing from previous session."
    check api.calls[2].kind == mockTriggerTyping

    let threadSession = getSessionForThread(db, api.calls[0].threadId)
    check threadSession.isSome
    check threadSession.get() == "sess_old123"

  test "mention in channel with no previous thread creates new session":
    let db = openTestDb()
    defer: db.close()
    let api = newMockDiscordApi()
    let bot = newDiscordBot(
      sendMessage = mockSendFn(api),
      triggerTyping = mockTypingFn(api),
      createThread = mockCreateThreadFn(api),
      archiveThread = mockArchiveThreadFn(api),
      db = db,
      config = makeConfig(),
      dispatcher = makeDispatcher(),
      shard = newMockShard("bot"),
    )

    let msg = Message(
      id: "msg_2",
      author: MockUser(id: "user1", username: "user1", bot: false),
      content: "<@bot> hello",
      channel_id: "chan2",
      guild_id: some("guild1"),
      mention_users: @[MockUser(id: "bot", username: "bot", bot: false)],
    )

    waitFor bot.onMessageCreate(msg)

    check api.calls.len >= 2
    check api.calls[0].kind == mockCreateThread
    check api.calls[0].name.startsWith("Talos-sess_")
    check api.calls[1].kind == mockTriggerTyping

    let threadSession = getSessionForThread(db, api.calls[0].threadId)
    check threadSession.isSome
    check threadSession.get().startsWith("sess_")

  test "message in active thread continues existing session without new thread":
    let db = openTestDb()
    defer: db.close()
    let api = newMockDiscordApi()
    let bot = newDiscordBot(
      sendMessage = mockSendFn(api),
      triggerTyping = mockTypingFn(api),
      createThread = mockCreateThreadFn(api),
      archiveThread = mockArchiveThreadFn(api),
      db = db,
      config = makeConfig(),
      dispatcher = makeDispatcher(),
      shard = newMockShard("bot"),
    )

    setThreadMapping(db, "thread_active", "sess_active", "chan3", "guild1")

    let msg = Message(
      id: "msg_3",
      author: MockUser(id: "user1", username: "user1", bot: false),
      content: "follow up",
      channel_id: "thread_active",
      guild_id: some("guild1"),
      mention_users: @[],
    )

    waitFor bot.onMessageCreate(msg)

    check api.calls.len == 1
    check api.calls[0].kind == mockTriggerTyping
    check getSessionForThread(db, "thread_active").get() == "sess_active"
