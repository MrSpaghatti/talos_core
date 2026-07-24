## Discord configuration types.

import file_path_validator

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
    fileSandboxDir*: string  ## Optional: confines file_read/file_write to this
                             ## directory (and its descendants) when set. Empty
                             ## by default — purely opt-in, no forced default.
    tools*: AccessControl
    daemonDelegation*: bool  ## Enable agent delegation and MCP tools in daemon mode

proc defaultDiscordConfig*(): DiscordConfig =
  result = DiscordConfig(
    tokenEnv: "DISCORD_BOT_TOKEN",
    prefix: "!",
    admins: AccessControl(allow: @[], deny: @[]),
    users: AccessControl(allow: @[], deny: @[]),
    # The mandatory deny patterns (file_path_validator.mandatoryDenyPatterns)
    # are always enforced independently of this list — this is just a
    # sensible starting default for the user-configurable deny list.
    fileRules: AccessControl(allow: @[], deny: mandatoryDenyPatterns),
    fileSandboxDir: "",
    tools: AccessControl(allow: @[], deny: @[]),
    daemonDelegation: false
  )
