## Discord bot module — Dependency Injection design.
##
## The DiscordBot ref object holds all injected dependencies as callback
## procs for the API, plus config, dispatcher, and shard. No global mutable
## state. The onMessageCreate handler is a method on the bot, making it
## testable with mock implementations.
##
## The API operations (sendMessage, triggerTyping, createThread, archiveThread)
## are injected as callback procs so that both MockDiscordApi and RealDiscordApi
## can be used without generics — avoiding Nim's {.async.} + generics limitation.

import std/[asyncdispatch, logging, options, strutils, times]
import db_connector/db_sqlite
import discord_mocks, discord_types, permission, discord_commands,
       agent_dispatcher, message_chunker
import dimscord
import discord_bridge
import thread_mapping

type
  SendMessageFn* = proc (channelId, content: string): Future[string] {.async, gcsafe.}
  TriggerTypingFn* = proc (channelId: string) {.async, gcsafe.}
  CreateThreadFn* = proc (channelId, messageId, name: string): Future[string] {.async, gcsafe.}
  ArchiveThreadFn* = proc (threadId: string) {.async, gcsafe.}

  DiscordBot* = ref object
    sendMessage*: SendMessageFn
    triggerTyping*: TriggerTypingFn
    createThread*: CreateThreadFn
    archiveThread*: ArchiveThreadFn
    db*: DbConn
    config*: DiscordConfig
    dispatcher*: AgentDispatcher
    shard*: MockShard

proc newDiscordBot*(sendMessage: SendMessageFn;
                     triggerTyping: TriggerTypingFn;
                     createThread: CreateThreadFn;
                     archiveThread: ArchiveThreadFn;
                     db: DbConn;
                     config: DiscordConfig;
                     dispatcher: AgentDispatcher;
                     shard: MockShard): DiscordBot =
  ## Create a DiscordBot with injected dependencies.
  DiscordBot(
    sendMessage: sendMessage,
    triggerTyping: triggerTyping,
    createThread: createThread,
    archiveThread: archiveThread,
    db: db,
    config: config,
    dispatcher: dispatcher,
    shard: shard,
  )

proc generateSessionId(): string =
  let t = now().utc
  return "sess_" & t.format("yyyyMMdd'T'HHmmss") & "_" & $getTime().nanosecond

proc onMessageCreate*(bot: DiscordBot; msg: discord_mocks.Message) {.async, gcsafe.} =
  ## Main message handler. Routes messages to commands or agent dispatch.
  ##
  ## 1. Ignore bot authors.
  ## 2. Check user is allowed (isUserAllowed).
  ## 3. If message starts with prefix → handle as command.
  ## 4. Otherwise, trigger typing and dispatch to agent.

  # 1. Ignore bots
  if msg.author.bot:
    return

  # 2. Check if user is allowed
  if not isUserAllowed(msg.author.id, bot.config):
    return

  # 3. Check for command prefix
  if msg.content.startsWith(bot.config.prefix):
    let withoutPrefix = msg.content[bot.config.prefix.len .. ^1]
    let parts = withoutPrefix.splitWhitespace(maxsplit=1)
    if parts.len == 0:
      return
    let cmd = parts[0]
    let args = if parts.len > 1: parts[1] else: ""
    let cmdResult = handleCommand(cmd, args, msg.author.id, bot.config)
    let chunks = chunkMessage(cmdResult.response)
    for chunk in chunks:
      discard await bot.sendMessage(msg.channel_id, chunk)
    # If the command returned an updated config, apply it
    if cmdResult.updatedConfig.isSome:
      bot.config = cmdResult.updatedConfig.get()
    return

  # 4. Ignore direct messages (not in a guild channel)
  if msg.guild_id.isNone:
    return

  # 5. Check for bot mention
  var mentionsBot = false
  for u in msg.mention_users:
    if u.id == bot.shard.userId:
      mentionsBot = true
      break

  # 6. Resolve thread/session, then dispatch agent
  let existingThreadSession = getSessionForThread(bot.db, msg.channel_id)
  if existingThreadSession.isSome:
    await bot.triggerTyping(msg.channel_id)
    let request = AgentRequest(
      userInput: msg.content,
      sessionId: existingThreadSession.get(),
      channelId: msg.channel_id,
      threadId: msg.channel_id,
    )
    await bot.dispatcher.dispatchAgent(request)
    return

  # 7. Ignore messages that don't mention the bot outside existing threads
  if not mentionsBot:
    return

  let previousSession = getLatestSessionForChannel(bot.db, msg.channel_id)
  if previousSession.isSome:
    let sessionId = previousSession.get()
    let threadName = "Talos-" & sessionId[0 ..< min(8, sessionId.len)]
    let threadId = await bot.createThread(msg.channel_id, msg.id, threadName)
    setThreadMapping(bot.db, threadId, sessionId, msg.channel_id, msg.guild_id.get(""))
    discard await bot.sendMessage(threadId, "Continuing from previous session.")
    await bot.triggerTyping(threadId)
    let request = AgentRequest(
      userInput: msg.content,
      sessionId: sessionId,
      channelId: threadId,
      threadId: threadId,
    )
    await bot.dispatcher.dispatchAgent(request)
    return

  let newSessionId = generateSessionId()
  let threadName = "Talos-" & newSessionId[0 ..< min(8, newSessionId.len)]
  let threadId = await bot.createThread(msg.channel_id, msg.id, threadName)
  setThreadMapping(bot.db, threadId, newSessionId, msg.channel_id, msg.guild_id.get(""))
  await bot.triggerTyping(threadId)

  let request = AgentRequest(
    userInput: msg.content,
    sessionId: newSessionId,
    channelId: threadId,
    threadId: threadId,
  )
  await bot.dispatcher.dispatchAgent(request)

# ---------------------------------------------------------------------------
# Live Discord bot (Dimscord gateway bridge)
# ---------------------------------------------------------------------------

proc startDiscordBot*(
  discord: DiscordClient;
  bot: DiscordBot;
): Future[void] {.async.} =
  ## Bridges the DI-based DiscordBot to Dimscord's gateway.
  ##
  ## Registers event handlers on the Dimscord client:
  ## - ``on_ready``: populates the bot's shard with the authenticated user.
  ## - ``message_create``: converts Dimscord messages to our internal type
  ##   and delegates to ``onMessageCreate``.
  ##
  ## Then starts the gateway session with the required intents.
  ##
  ## The caller must create the ``DiscordClient`` and ``DiscordBot`` before
  ## calling this proc.  Returns when the session ends or an error occurs.

  var l = newConsoleLogger(fmtStr = "[$datetime] - $msg ", useStderr = true)
  addHandler(l)

  discord.events.on_ready = proc (s: Shard, r: Ready) {.async, gcsafe.} =
    bot.shard.userId = r.user.id
    bot.shard.user = MockUser(id: r.user.id, username: r.user.username, bot: true)
    notice("[daemon] Connected as " & r.user.username & " (" & r.user.id & ")")

  discord.events.message_create = proc (s: Shard, m: dimscord.Message) {.async, gcsafe.} =
    let internalMsg = convertMessage(m)
    await onMessageCreate(bot, internalMsg)

  await discord.startSession(
    gateway_intents = {giGuildMessages, giMessageContent}
  )
