## Discord configuration types.

type
  AccessControl* = object
    allow*: seq[string]
    deny*: seq[string]

  DiscordConfig* = object
    tokenEnv*: string
    prefix*: string
    admins*: AccessControl
    users*: AccessControl
    fileRules*: AccessControl
    tools*: AccessControl
    daemonDelegation*: bool  ## Enable agent delegation and MCP tools in daemon mode

proc defaultDiscordConfig*(): DiscordConfig =
  result = DiscordConfig(
    tokenEnv: "DISCORD_BOT_TOKEN",
    prefix: "!",
    admins: AccessControl(allow: @[], deny: @[]),
    users: AccessControl(allow: @[], deny: @[]),
    fileRules: AccessControl(allow: @[], deny: @[".env", ".ssh", ".aws", ".gnupg", "*.key", "*.pem"]),
    tools: AccessControl(allow: @[], deny: @[]),
    daemonDelegation: false
  )
