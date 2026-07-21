## Real Discord API adapter.
##
## Bridges the mock-based DiscordBot interface to the actual Dimscord
## REST API client. Each proc mirrors the MockDiscordApi procedural
## interface so that DiscordBot can be wired with either mock or real
## dependencies.
##
## All procs are async because the underlying Dimscord REST calls are
## async. The MockDiscordApi procs are also async for interface
## compatibility, though they resolve immediately.

import std/[asyncdispatch, json, options]
import dimscord
import dimscord/restapi/requester  # needed for RestApi.request
import discord_mocks

type
  RealDiscordApi* = ref object
    ## Thin adapter over Dimscord's RestApi. Holds a reference to the
    ## client's REST API so calls can be made without touching the
    ## gateway event loop.
    restApi: RestApi

proc newRealDiscordApi*(restApi: RestApi): RealDiscordApi =
  ## Creates a RealDiscordApi wrapping the given Dimscord RestApi.
  RealDiscordApi(restApi: restApi)

proc sendMessage*(api: RealDiscordApi; channelId, content: string): Future[string] {.async.} =
  ## Sends a message to the given channel. Returns the message ID.
  let msg = await api.restApi.sendMessage(channelId, content)
  return msg.id

proc triggerTyping*(api: RealDiscordApi; channelId: string) {.async.} =
  ## Triggers the typing indicator in the given channel.
  await api.restApi.startTyping(channelId)

proc createThread*(api: RealDiscordApi; channelId, messageId, name: string): Future[string] {.async.} =
  ## Creates a public thread under the given channel, anchored to the
  ## specified message. Returns the new thread's channel ID.
  let thread = await api.restApi.startThreadWithMessage(
    channelId, messageId, name, auto_archive_duration = 60
  )
  return thread.id

proc archiveThread*(api: RealDiscordApi; threadId: string) {.async.} =
  ## Archives a thread by PATCHing the channel with archived=true.
  ## Uses the raw REST API because editGuildChannel doesn't expose
  ## the archived flag directly.
  discard await api.restApi.request(
    "PATCH",
    endpointChannels(threadId),
    $ %*{"archived": true}
  )

proc convertMessage*(msg: dimscord.Message): MockMessage =
  ## Converts a Dimscord Message to our internal MockMessage type
  ## so it can be fed to DiscordBot.onMessageCreate.
  var guildId: Option[string] = none[string]()
  if msg.guild_id.isSome:
    guildId = msg.guild_id
  var mentionUsers: seq[MockUser] = @[]
  for u in msg.mention_users:
    mentionUsers.add(MockUser(id: u.id, username: u.username, bot: u.bot))
  result = MockMessage(
    id: msg.id,
    author: MockUser(id: msg.author.id, username: msg.author.username, bot: msg.author.bot),
    content: msg.content,
    channel_id: msg.channel_id,
    guild_id: guildId,
    mention_users: mentionUsers,
  )
