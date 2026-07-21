## Discord bot command handler.
##
## Parses and handles prefix commands: !config, !status, !admin, !session.
## All responses are plain text (no embeds).
## Admin-only commands are gated by the permission module's isAdmin check.

import std/[options, sequtils, strutils, times]
import discord_types
import permission

type
  CommandResult* = object
    response*: string
    updatedConfig*: Option[DiscordConfig]

proc handleConfigCommand*(args: string, authorId: string, cfg: DiscordConfig): CommandResult =
  ## Handle !config subcommands: show, set, reload, allowlist
  let parts = args.splitWhitespace(maxsplit=2)

  if parts.len == 0 or parts[0].len == 0:
    return CommandResult(response: "Usage: !config <show|set|reload|allowlist>", updatedConfig: none[DiscordConfig]())

  let subcmd = parts[0].toLowerAscii()

  case subcmd
  of "show":
    var lines: seq[string] = @[]
    lines.add("Prefix: " & cfg.prefix)
    lines.add("Token env: ******")
    lines.add("Admins: " & cfg.admins.allow.join(", "))
    lines.add("Users: " & cfg.users.allow.join(", "))
    lines.add("File allowlist: " & cfg.fileRules.allow.join(", "))
    lines.add("File denylist: " & cfg.fileRules.deny.join(", "))
    lines.add("Tool allowlist: " & cfg.tools.allow.join(", "))
    lines.add("Tool denylist: " & cfg.tools.deny.join(", "))
    return CommandResult(response: lines.join("\n"), updatedConfig: none[DiscordConfig]())

  of "set":
    if not isAdmin(authorId, cfg):
      return CommandResult(response: "Permission denied: admin required.", updatedConfig: none[DiscordConfig]())
    if parts.len < 3:
      return CommandResult(response: "Usage: !config set <key> <value>", updatedConfig: none[DiscordConfig]())
    let key = parts[1].toLowerAscii()
    let value = parts[2]
    var newCfg = cfg
    case key
    of "prefix":
      newCfg.prefix = value
      return CommandResult(response: "Prefix set to: " & value, updatedConfig: some(newCfg))
    of "token_env":
      newCfg.tokenEnv = value
      return CommandResult(response: "Token env set to: " & value, updatedConfig: some(newCfg))
    else:
      return CommandResult(response: "Unknown config key: " & key, updatedConfig: none[DiscordConfig]())

  of "reload":
    if not isAdmin(authorId, cfg):
      return CommandResult(response: "Permission denied: admin required.", updatedConfig: none[DiscordConfig]())
    # Placeholder: actual reload from disk is handled by the bot event loop
    return CommandResult(response: "Config reload requested. Reload must be handled by the bot runtime.", updatedConfig: none[DiscordConfig]())

  of "allowlist":
    let allowlistParts = if parts.len >= 2: parts[1 .. ^1] else: @[]
    if allowlistParts.len == 0:
      return CommandResult(response: "Usage: !config allowlist <add|remove|list> [path]", updatedConfig: none[DiscordConfig]())

    let allowlistCmd = allowlistParts[0].toLowerAscii()

    case allowlistCmd
    of "add":
      if not isAdmin(authorId, cfg):
        return CommandResult(response: "Permission denied: admin required.", updatedConfig: none[DiscordConfig]())
      if allowlistParts.len < 2:
        return CommandResult(response: "Usage: !config allowlist add <path>", updatedConfig: none[DiscordConfig]())
      let path = allowlistParts[1]
      var newCfg = cfg
      if path notin newCfg.fileRules.allow:
        newCfg.fileRules.allow.add(path)
      return CommandResult(response: "Added '" & path & "' to file allowlist.", updatedConfig: some(newCfg))

    of "remove":
      if not isAdmin(authorId, cfg):
        return CommandResult(response: "Permission denied: admin required.", updatedConfig: none[DiscordConfig]())
      if allowlistParts.len < 2:
        return CommandResult(response: "Usage: !config allowlist remove <path>", updatedConfig: none[DiscordConfig]())
      let path = allowlistParts[1]
      var newCfg = cfg
      newCfg.fileRules.allow.keepItIf(it != path)
      return CommandResult(response: "Removed '" & path & "' from file allowlist.", updatedConfig: some(newCfg))

    of "list":
      if cfg.fileRules.allow.len == 0:
        return CommandResult(response: "File allowlist is empty.", updatedConfig: none[DiscordConfig]())
      return CommandResult(response: "File allowlist:\n" & cfg.fileRules.allow.join("\n"), updatedConfig: none[DiscordConfig]())

    else:
      return CommandResult(response: "Unknown allowlist subcommand: " & allowlistCmd, updatedConfig: none[DiscordConfig]())

  else:
    return CommandResult(response: "Unknown config subcommand: " & subcmd, updatedConfig: none[DiscordConfig]())

proc handleStatusCommand*(authorId: string, cfg: DiscordConfig): CommandResult =
  ## Handle !status — show bot status (uptime, sessions, model).
  ## This is a placeholder; actual runtime data would be injected by the bot.
  let now = getTime().utc().format("yyyy-MM-dd HH:mm:ss")
  var lines: seq[string] = @[]
  lines.add("Bot status as of " & now)
  lines.add("Prefix: " & cfg.prefix)
  lines.add("Admins: " & cfg.admins.allow.join(", "))
  lines.add("Sessions: (not tracked in command handler)")
  lines.add("Model: (not tracked in command handler)")
  return CommandResult(response: lines.join("\n"), updatedConfig: none[DiscordConfig]())

proc handleAdminCommand*(args: string, authorId: string, cfg: DiscordConfig): CommandResult =
  ## Handle !admin subcommands: restart, reconnect (placeholders).
  let parts = args.splitWhitespace(maxsplit=1)

  if parts.len == 0 or parts[0].len == 0:
    return CommandResult(response: "Usage: !admin <restart|reconnect>", updatedConfig: none[DiscordConfig]())

  let subcmd = parts[0].toLowerAscii()

  if not isAdmin(authorId, cfg):
    return CommandResult(response: "Permission denied: admin required.", updatedConfig: none[DiscordConfig]())

  case subcmd
  of "restart":
    # Placeholder: actual restart handled by bot runtime
    return CommandResult(response: "Restart requested. Restart must be handled by the bot runtime.", updatedConfig: none[DiscordConfig]())
  of "reconnect":
    # Placeholder: actual reconnect handled by bot runtime
    return CommandResult(response: "Reconnect requested. Reconnect must be handled by the bot runtime.", updatedConfig: none[DiscordConfig]())
  else:
    return CommandResult(response: "Unknown admin subcommand: " & subcmd, updatedConfig: none[DiscordConfig]())

proc handleSessionCommand*(args: string, authorId: string, cfg: DiscordConfig): CommandResult =
  ## Handle !session subcommands: list, info, clear.
  let parts = args.splitWhitespace(maxsplit=1)

  if parts.len == 0 or parts[0].len == 0:
    return CommandResult(response: "Usage: !session <list|info|clear>", updatedConfig: none[DiscordConfig]())

  let subcmd = parts[0].toLowerAscii()

  case subcmd
  of "list":
    # Placeholder: actual session data would come from memory module
    return CommandResult(response: "Active sessions: (not tracked in command handler)", updatedConfig: none[DiscordConfig]())

  of "info":
    if parts.len < 2:
      return CommandResult(response: "Usage: !session info <session_id>", updatedConfig: none[DiscordConfig]())
    let sessionId = parts[1]
    # Placeholder: actual session data would come from memory module
    return CommandResult(response: "Session info for " & sessionId & ": (not tracked in command handler)", updatedConfig: none[DiscordConfig]())

  of "clear":
    if not isAdmin(authorId, cfg):
      return CommandResult(response: "Permission denied: admin required.", updatedConfig: none[DiscordConfig]())
    if parts.len < 2:
      return CommandResult(response: "Usage: !session clear <session_id>", updatedConfig: none[DiscordConfig]())
    let sessionId = parts[1]
    # Placeholder: actual clear would be handled by memory module
    return CommandResult(response: "Session " & sessionId & " memory clear requested. Clear must be handled by the bot runtime.", updatedConfig: none[DiscordConfig]())

  else:
    return CommandResult(response: "Unknown session subcommand: " & subcmd, updatedConfig: none[DiscordConfig]())

proc handleCommand*(cmd: string, args: string, authorId: string, cfg: DiscordConfig): CommandResult =
  ## Main command dispatcher.
  ## cmd: the command name without prefix (e.g. "config", "status")
  ## args: everything after the command word
  ## authorId: the Discord user ID of the message author
  ## cfg: current DiscordConfig
  ##
  ## Returns CommandResult with response text and optional updated config.
  let command = cmd.toLowerAscii()

  case command
  of "config":
    return handleConfigCommand(args, authorId, cfg)
  of "status":
    return handleStatusCommand(authorId, cfg)
  of "admin":
    return handleAdminCommand(args, authorId, cfg)
  of "session":
    return handleSessionCommand(args, authorId, cfg)
  else:
    return CommandResult(response: "Unknown command: " & cmd, updatedConfig: none[DiscordConfig]())