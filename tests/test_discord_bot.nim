import unittest
import std/[asyncdispatch, options, strutils]
import db_connector/db_sqlite
import talos_core/discord
import talos_core/discord_mocks
import talos_core/discord_types
import talos_core/agent_dispatcher
import talos_core/thread_mapping

suite "DiscordBot (DI-based)":

  proc makeConfig(admins: seq[string] = @[], users: seq[string] = @[]): DiscordConfig =
    result = defaultDiscordConfig()
    result.admins.allow = admins
    result.users.allow = users

  proc makeDb(): DbConn =
    let db = open(":memory:", "", "", "")
    initThreadMappingSchema(db)
    return db

  proc makeBot(admins: seq[string] = @["admin1"], users: seq[string] = @[]): tuple[bot: DiscordBot, api: MockDiscordApi, db: DbConn] =
    let api = newMockDiscordApi()
    let cfg = makeConfig(admins = admins, users = users)
    let dispatcher = newAgentDispatcher(proc(r: AgentResult) = discard)
    let shard = newMockShard("bot_user_id")
    let db = makeDb()
    let bot = newDiscordBot(
      sendMessage = mockSendFn(api),
      triggerTyping = mockTypingFn(api),
      createThread = mockCreateThreadFn(api),
      archiveThread = mockArchiveThreadFn(api),
      db = db,
      config = cfg,
      dispatcher = dispatcher,
      shard = shard,
    )
    return (bot, api, db)

  test "bot messages are ignored":
    let (bot, api, db) = makeBot()
    defer: db.close()
    let msg = Message(
      id: "msg_bot",
      author: MockUser(id: "bot1", username: "BotUser", bot: true),
      content: "!status",
      channel_id: "chan1",
      guild_id: some("guild1"),
      mention_users: @[MockUser(id: "bot_user_id", username: "bot_user_id", bot: true)],
    )
    bot.shard.userId = "bot_user_id"
    waitFor bot.onMessageCreate(msg)
    check api.calls.len == 0

  test "unknown users are ignored":
    let (bot, api, db) = makeBot(admins = @["admin1"], users = @["user1"])
    defer: db.close()
    let msg = Message(
      id: "msg_unknown",
      author: MockUser(id: "stranger", username: "Stranger", bot: false),
      content: "hello",
      channel_id: "chan1",
      guild_id: some("guild1"),
      mention_users: @[MockUser(id: "bot_user_id", username: "bot_user_id", bot: true)],
    )
    bot.shard.userId = "bot_user_id"
    waitFor bot.onMessageCreate(msg)
    check api.calls.len == 0

  test "command with prefix is handled":
    let (bot, api, db) = makeBot(users = @["user1"])
    defer: db.close()
    let msg = Message(
      id: "msg_cmd_1",
      author: MockUser(id: "user1", username: "TestUser", bot: false),
      content: "!status",
      channel_id: "chan1",
      guild_id: some("guild1"),
      mention_users: @[MockUser(id: "bot_user_id", username: "bot_user_id", bot: true)],
    )
    bot.shard.userId = "bot_user_id"
    waitFor bot.onMessageCreate(msg)
    check api.calls.len >= 1
    var foundSend = false
    for call in api.calls:
      if call.kind == mockSendMessage:
        foundSend = true
        check call.channelId in ["chan1", "thread_1"]
    check foundSend

  test "unknown command returns unknown command message":
    let (bot, api, db) = makeBot(users = @["user1"])
    defer: db.close()
    let msg = Message(
      id: "msg_cmd_3",
      author: MockUser(id: "user1", username: "TestUser", bot: false),
      content: "!foobar",
      channel_id: "chan1",
      guild_id: some("guild1"),
      mention_users: @[MockUser(id: "bot_user_id", username: "bot_user_id", bot: true)],
    )
    bot.shard.userId = "bot_user_id"
    waitFor bot.onMessageCreate(msg)
    var foundResponse = false
    for call in api.calls:
      if call.kind == mockSendMessage:
        foundResponse = true
        check "Unknown" in call.content or "unknown" in call.content
    check foundResponse

  test "config set command updates bot config":
    let (bot, _, db) = makeBot(admins = @["admin1"], users = @["admin1"])
    defer: db.close()
    check bot.config.prefix == "!"
    let msg = Message(
      id: "msg_cfg_1",
      author: MockUser(id: "admin1", username: "Admin", bot: false),
      content: "!config set prefix ?",
      channel_id: "chan1",
      guild_id: some("guild1"),
      mention_users: @[MockUser(id: "bot_user_id", username: "bot_user_id", bot: true)],
    )
    bot.shard.userId = "bot_user_id"
    waitFor bot.onMessageCreate(msg)
    check bot.config.prefix == "?"

  test "regular message triggers typing and dispatches a real agent request":
    let api = newMockDiscordApi()
    let cfg = makeConfig(admins = @["admin1"], users = @["user1"])
    var received: AgentResult
    let dispatcher = newAgentDispatcher(proc(r: AgentResult) {.gcsafe, closure, raises: [].} =
      {.cast(gcsafe), cast(raises: []).}:
        received = r)
    let shard = newMockShard("bot_user_id")
    let db = makeDb()
    let bot = newDiscordBot(
      sendMessage = mockSendFn(api),
      triggerTyping = mockTypingFn(api),
      createThread = mockCreateThreadFn(api),
      archiveThread = mockArchiveThreadFn(api),
      db = db,
      config = cfg,
      dispatcher = dispatcher,
      shard = shard,
    )
    defer: db.close()
    let msg = Message(
      id: "msg_reg_1",
      author: MockUser(id: "user1", username: "TestUser", bot: false),
      content: "hello agent",
      channel_id: "chan1",
      guild_id: some("guild1"),
      mention_users: @[MockUser(id: "bot_user_id", username: "bot_user_id", bot: true)],
    )
    bot.shard.userId = "bot_user_id"
    waitFor bot.onMessageCreate(msg)
    var foundTyping = false
    for call in api.calls:
      if call.kind == mockTriggerTyping:
        foundTyping = true
        # Typing should happen in the newly created thread, not the original channel
        check call.channelId == "thread_1"
    check foundTyping

    # The placeholder dispatcher (no cfg/llm) echoes userInput straight
    # back as "Agent response for: <input>" — using that as a probe proves
    # the AgentRequest actually built from the Discord message carries the
    # right content and channel/thread routing, not just that *some*
    # dispatch happened with unknown contents.
    check received.responseText == "Agent response for: hello agent"
    check received.channelId == "thread_1"

  test "prefix-only message with no command is ignored":
    let (bot, api, db) = makeBot(users = @["user1"])
    defer: db.close()
    let msg = Message(
      id: "msg_prefix_only",
      author: MockUser(id: "user1", username: "TestUser", bot: false),
      content: "!",
      channel_id: "chan1",
      guild_id: some("guild1"),
      mention_users: @[MockUser(id: "bot_user_id", username: "bot_user_id", bot: true)],
    )
    bot.shard.userId = "bot_user_id"
    bot.shard.userId = "bot_user_id"
    waitFor bot.onMessageCreate(msg)
    check api.calls.len == 0

  test "admin command denied for non-admin user":
    let (bot, api, db) = makeBot(admins = @["admin1"], users = @["user1"])
    defer: db.close()
    let msg = Message(
      id: "msg_admin_denied",
      author: MockUser(id: "user1", username: "RegularUser", bot: false),
      content: "!admin restart",
      channel_id: "chan1",
      guild_id: some("guild1"),
      mention_users: @[MockUser(id: "bot_user_id", username: "bot_user_id", bot: true)],
    )
    bot.shard.userId = "bot_user_id"
    waitFor bot.onMessageCreate(msg)
    var foundResponse = false
    for call in api.calls:
      if call.kind == mockSendMessage:
        foundResponse = true
        check "permission" in call.content.toLowerAscii or "denied" in call.content.toLowerAscii
    check foundResponse

  test "direct messages (no guild) are silently ignored, never dispatched":
    ## A DM to the bot has no guild_id. Users expect the bot to only act in
    ## guild channels/threads it's configured for — never reply to DMs.
    let (bot, api, db) = makeBot(users = @["user1"])
    defer: db.close()
    let msg = Message(
      id: "msg_dm",
      author: MockUser(id: "user1", username: "TestUser", bot: false),
      content: "hey, got a sec?",
      channel_id: "dm_channel",
      guild_id: none(string),
      mention_users: @[MockUser(id: "bot_user_id", username: "bot_user_id", bot: true)],
    )
    bot.shard.userId = "bot_user_id"
    waitFor bot.onMessageCreate(msg)
    check api.calls.len == 0

  test "ordinary channel chatter that doesn't mention the bot and isn't in an existing thread is ignored":
    ## A user shouldn't get a reply just for talking in a channel the bot is
    ## present in — only an explicit @mention (or a reply inside a thread
    ## the bot already opened) should trigger a response.
    let (bot, api, db) = makeBot(users = @["user1"])
    defer: db.close()
    let msg = Message(
      id: "msg_chatter",
      author: MockUser(id: "user1", username: "TestUser", bot: false),
      content: "anyone around?",
      channel_id: "chan_general",
      guild_id: some("guild1"),
      mention_users: @[],
    )
    bot.shard.userId = "bot_user_id"
    waitFor bot.onMessageCreate(msg)
    check api.calls.len == 0
