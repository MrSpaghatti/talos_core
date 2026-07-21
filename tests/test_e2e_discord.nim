import unittest
import std/[asyncdispatch, options, os, strutils, json, times]
import db_connector/db_sqlite

import talos_core/[discord, discord_mocks, discord_types, discord_commands,
  permission, agent_dispatcher, file_tool, file_path_validator, thread_mapping,
  tool_registry, config]
import mock_llm_server

suite "End-to-end Discord Integration":
  var
    db: DbConn
    api: MockDiscordApi
    bot: DiscordBot
    shard: MockShard
    dispatcher: AgentDispatcher
    config: DiscordConfig

  setup:
    db = open(":memory:", "", "", "")
    initThreadMappingSchema(db)

    api = newMockDiscordApi()
    shard = newMockShard("bot_user_id")

    config = defaultDiscordConfig()
    config.admins.allow.add("admin_user")
    config.users.allow.add("regular_user")

    dispatcher = newAgentDispatcher(proc(res: AgentResult) {.gcsafe, closure.} =
      discard  # callback: test verifies bot behavior via api.calls inspection
    )

    bot = newDiscordBot(
      sendMessage = mockSendFn(api),
      triggerTyping = mockTypingFn(api),
      createThread = mockCreateThreadFn(api),
      archiveThread = mockArchiveThreadFn(api),
      db = db,
      config = config,
      dispatcher = dispatcher,
      shard = shard
    )

  teardown:
    db.close()

  # "Mention creates a thread and dispatches" and "message in an existing
  # thread continues the session without creating a new one" are covered
  # more precisely (exact session-ID equality, call-ordering) by
  # test_thread_reconnection.nim's "thread reconnection" suite, which
  # exercises the same bot.onMessageCreate entry point.

  test "Bot commands: !status, !admin restart, !config set":
    let statusMsg = makeMessage("regular_user", "!status", "channel_1", "guild_1", @[])
    waitFor onMessageCreate(bot, statusMsg)

    var statusFound = false
    for call in api.calls:
      if call.kind == mockSendMessage and "status" in call.content.toLowerAscii:
        statusFound = true
    check statusFound

    api.calls = @[]
    
    let adminRestart = makeMessage("regular_user", "!admin restart", "channel_1", "guild_1", @[])
    waitFor onMessageCreate(bot, adminRestart)
    
    var deniedFound = false
    for call in api.calls:
      if call.kind == mockSendMessage and "permission denied" in call.content.toLowerAscii:
        deniedFound = true
    check deniedFound

    api.calls = @[]

    let configSet = makeMessage("admin_user", "!config set prefix ?", "channel_1", "guild_1", @[])
    waitFor onMessageCreate(bot, configSet)
    
    check bot.config.prefix == "?"
    
  test "File tool configuration":
    writeFile("test_allowed.txt", "allowed")
    writeFile(".env_test", "secret")
    try:
      let rules = FileRules(
        sandboxDir: getCurrentDir(),
        allowPatterns: @["*"],
        askPatterns: @[],
        denyPatterns: @[".env*"]
      )
      let readTool = fileReadTool(rules)
      let allowedArgs = %*{"path": "test_allowed.txt"}
      let allowedResult = readTool.execute(allowedArgs)
      check "allowed" in allowedResult.output
      let deniedArgs = %*{"path": ".env_test"}
      let deniedResult = readTool.execute(deniedArgs)
      check "Access denied" in deniedResult.output
    finally:
      try: removeFile("test_allowed.txt") except CatchableError: discard
      try: removeFile(".env_test") except CatchableError: discard

  # "Thread archival": mentioning the bot again after its thread was
  # archived creates a new thread but reuses the old session — this is
  # test_thread_reconnection.nim's "archived thread creates new thread and
  # reuses old session" test, with more precise assertions (exact session
  # ID, call ordering) than this suite had.

# ---------------------------------------------------------------------------
# Real user scenario: a Discord user has a conversation across two messages
# in the same thread and expects the bot to remember what they said. This
# suite runs the *production* dispatcher (real runAgentLoop against a mock
# LLM, real file-backed memory) through the actual bot.onMessageCreate
# entry point — not just dispatchAgent directly — so it proves the fix
# end-to-end through the exact path a real Discord message takes.
# ---------------------------------------------------------------------------

proc chatResponseBody(text: string): string =
  """{"id": "chatcmpl-e2e", "object": "chat.completion", "model": "mock",
  "choices": [{"index": 0, "message": {"role": "assistant", "content": """ &
  $(%text) & """}, "finish_reason": "stop"}],
  "usage": {"prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8}}"""

suite "End-to-end Discord Integration: real conversation continuity":
  var
    db: DbConn
    api: MockDiscordApi
    bot: DiscordBot
    shard: MockShard
    server: MockServer
    dbPath: string

  setup:
    db = open(":memory:", "", "", "")
    initThreadMappingSchema(db)

    server = startMockServer()
    dbPath = getTempDir() / ("talos_e2e_discord_" & $getTime().toUnix() &
                              "_" & $getCurrentProcessId() & ".db")
    for suffix in ["", "-wal", "-shm"]:
      try: removeFile(dbPath & suffix)
      except OSError: discard

    api = newMockDiscordApi()
    shard = newMockShard("bot_user_id")

    var cfg = defaultConfig()
    cfg.discord.admins.allow.add("admin_user")
    cfg.discord.users.allow.add("regular_user")

    let llm = makeClient(server)
    let reg = newToolRegistry()
    let sendFn = mockSendFn(api)
    # Mirrors production wiring (talos_agent.nim cmdDaemon): the
    # dispatcher's callback is what actually delivers the agent's reply
    # back to the channel/thread the user is in.
    let callbackProc = proc(r: AgentResult) {.gcsafe, closure, raises: [].} =
      {.cast(gcsafe), cast(raises: []).}:
        try: discard waitFor sendFn(r.channelId, r.responseText)
        except CatchableError: discard
    let dispatcher = newAgentDispatcher(
      callbackProc, cfg, llm, reg, dbPath)

    bot = newDiscordBot(
      sendMessage = sendFn,
      triggerTyping = mockTypingFn(api),
      createThread = mockCreateThreadFn(api),
      archiveThread = mockArchiveThreadFn(api),
      db = db,
      config = cfg.discord,
      dispatcher = dispatcher,
      shard = shard,
    )

  teardown:
    db.close()
    stopMockServer(server)
    for suffix in ["", "-wal", "-shm"]:
      try: removeFile(dbPath & suffix)
      except OSError: discard

  test "bot remembers what the user said earlier in the same thread":
    server.enqueue("200 OK", chatResponseBody("Nice to meet you, Alice!"))
    server.enqueue("200 OK",
      chatResponseBody("Your name is Alice, you told me earlier."))

    # Turn 1: user mentions the bot in a channel — a new thread is created.
    let msg1 = makeMessage(
      "regular_user", "Hi, my name is Alice", "channel_1", "guild_1",
      @["bot_user_id"])
    waitFor onMessageCreate(bot, msg1)

    var threadId = ""
    for call in api.calls:
      if call.kind == mockCreateThread:
        threadId = call.threadId
    check threadId != ""

    var firstReplySent = false
    for call in api.calls:
      if call.kind == mockSendMessage and call.channelId == threadId and
          "Nice to meet you, Alice" in call.content:
        firstReplySent = true
    check firstReplySent

    # Turn 2: user replies inside the thread (no mention needed — it's an
    # existing mapped thread), asking the bot to recall what they said.
    let msg2 = makeMessage(
      "regular_user", "What's my name?", threadId, "guild_1", @[])
    waitFor onMessageCreate(bot, msg2)

    var secondReplySent = false
    for call in api.calls:
      if call.kind == mockSendMessage and call.channelId == threadId and
          "you told me earlier" in call.content:
        secondReplySent = true
    check secondReplySent

    # The real proof of continuity: the SECOND request sent to the LLM
    # must contain the FIRST message's text, or the model could never
    # have answered "What's my name?" correctly.
    check server.requestCount == 2
    check "Hi, my name is Alice" in server.requestBodies[1]
