import std/[asyncdispatch, options, unittest]
import talos_core/discord_mocks

suite "Discord mocks":
  test "records discord api calls in order":
    let api = newMockDiscordApi()

    let messageId = waitFor api.sendMessage("channel-1", "hello")
    let threadId = waitFor api.createThread("channel-1", messageId, "thread-name")
    waitFor api.triggerTyping("channel-1")
    waitFor api.archiveThread(threadId)

    check messageId == "msg_1"
    check threadId == "thread_1"
    check api.calls.len == 4
    check api.calls[0].kind == mockSendMessage
    check api.calls[0].channelId == "channel-1"
    check api.calls[0].content == "hello"
    check api.calls[0].messageId == messageId
    check api.calls[1].kind == mockCreateThread
    check api.calls[1].name == "thread-name"
    check api.calls[1].threadId == threadId
    check api.calls[2].kind == mockTriggerTyping
    check api.calls[3].kind == mockArchiveThread

  test "stores shard state and message metadata":
    let shard = newMockShard("bot-123", @["member-1", "member-2"])
    let msg = makeMessage(
      authorId = "user-1",
      content = "ping",
      channelId = "channel-9",
      guildId = some("guild-7"),
      mentionUsers = @["bot-123"]
    )
    let dm = makeMessage(
      authorId = "user-2",
      content = "dm",
      channelId = "dm-channel",
      guildId = none(string),
      mentionUsers = @[]
    )

    check shard.userId == "bot-123"
    check shard.user.id == "bot-123"
    check shard.guildMembers == @["member-1", "member-2"]
    check msg.author.id == "user-1"
    check msg.content == "ping"
    check msg.channel_id == "channel-9"
    check msg.guild_id == some("guild-7")
    check msg.mention_users.len == 1
    check msg.mention_users[0].id == "bot-123"
    check dm.guild_id.isNone
    check dm.channel_id == "dm-channel"
