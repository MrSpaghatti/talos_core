import std/[asyncdispatch, options]

type
  MockUser* = object
    id*: string
    username*: string
    bot*: bool

  MockMessage* = object
    id*: string
    author*: MockUser
    content*: string
    channel_id*: string
    guild_id*: Option[string]
    mention_users*: seq[MockUser]

  Message* = MockMessage

  MockShard* = object
    userId*: string
    guildMembers*: seq[string]
    user*: MockUser

  MockApiCallKind* = enum
    mockSendMessage, mockCreateThread, mockTriggerTyping, mockArchiveThread

  MockApiCall* = object
    kind*: MockApiCallKind
    channelId*: string
    content*: string
    messageId*: string
    name*: string
    threadId*: string

  MockDiscordApi* = ref object
    calls*: seq[MockApiCall]
    nextMessageId: int
    nextThreadId: int

proc newMockDiscordApi*(): MockDiscordApi =
  MockDiscordApi(calls: @[], nextMessageId: 0, nextThreadId: 0)

proc sendMessage*(api: MockDiscordApi; channelId, content: string): Future[string] {.async.} =
  api.nextMessageId.inc
  let msgId = "msg_" & $api.nextMessageId
  api.calls.add MockApiCall(
    kind: mockSendMessage,
    channelId: channelId,
    content: content,
    messageId: msgId,
  )
  return msgId

proc createThread*(api: MockDiscordApi; channelId, messageId, name: string): Future[string] {.async.} =
  api.nextThreadId.inc
  let threadId = "thread_" & $api.nextThreadId
  api.calls.add MockApiCall(
    kind: mockCreateThread,
    channelId: channelId,
    messageId: messageId,
    name: name,
    threadId: threadId,
  )
  return threadId

proc triggerTyping*(api: MockDiscordApi; channelId: string) {.async.} =
  api.calls.add MockApiCall(kind: mockTriggerTyping, channelId: channelId)

proc archiveThread*(api: MockDiscordApi; threadId: string) {.async, gcsafe.} =
  api.calls.add MockApiCall(kind: mockArchiveThread, threadId: threadId)

proc newMockShard*(userId: string; guildMembers: seq[string] = @[]): MockShard =
  result.userId = userId
  result.guildMembers = guildMembers
  result.user = MockUser(id: userId, username: userId, bot: false)

proc makeMessage*(authorId, content, channelId, guildId: string; mentionUsers: seq[string]): Message =
  result = Message(
    id: "",
    author: MockUser(id: authorId, username: authorId, bot: false),
    content: content,
    channel_id: channelId,
    guild_id: some(guildId),
    mention_users: @[],
  )
  for userId in mentionUsers:
    result.mention_users.add MockUser(id: userId, username: userId, bot: false)

proc makeMessage*(authorId, content, channelId: string; guildId: Option[string]; mentionUsers: seq[string]): Message =
  result = Message(
    id: "",
    author: MockUser(id: authorId, username: authorId, bot: false),
    content: content,
    channel_id: channelId,
    guild_id: guildId,
    mention_users: @[],
  )
  for userId in mentionUsers:
    result.mention_users.add MockUser(id: userId, username: userId, bot: false)

proc mockSendFn*(api: MockDiscordApi): proc (channelId, content: string): Future[string] {.async, gcsafe.} =
  proc send(channelId, content: string): Future[string] {.async, gcsafe.} =
    return await api.sendMessage(channelId, content)
  return send

proc mockTypingFn*(api: MockDiscordApi): proc (channelId: string) {.async, gcsafe.} =
  proc typing(channelId: string) {.async, gcsafe.} =
    await api.triggerTyping(channelId)
  return typing

proc mockCreateThreadFn*(api: MockDiscordApi): proc (channelId, messageId, name: string): Future[string] {.async, gcsafe.} =
  proc create(channelId, messageId, name: string): Future[string] {.async, gcsafe.} =
    return await api.createThread(channelId, messageId, name)
  return create

proc mockArchiveThreadFn*(api: MockDiscordApi): proc (threadId: string) {.async, gcsafe.} =
  proc archive(threadId: string) {.async, gcsafe.} =
    await api.archiveThread(threadId)
  return archive
