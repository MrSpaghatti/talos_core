import unittest
import std/[options, strutils]
import talos_core/discord_types
import talos_core/discord_commands

suite "Discord Command Handler":

  # ── Helpers ──────────────────────────────────────────────────────────

  proc makeConfig(admins: seq[string] = @[], users: seq[string] = @[]): DiscordConfig =
    result = defaultDiscordConfig()
    result.admins.allow = admins
    result.users.allow = users

  proc makeAdminConfig(): DiscordConfig =
    makeConfig(admins = @["admin1"], users = @["user1"])

  # ── Command parsing ──────────────────────────────────────────────────

  test "handleCommand returns unknown command for empty input":
    let cfg = makeAdminConfig()
    let r = handleCommand("", "", "admin1", cfg)
    check "Unknown" in r.response or "unknown" in r.response

  test "handleCommand returns unknown command for unrecognized command":
    let cfg = makeAdminConfig()
    let r = handleCommand("foobar", "", "admin1", cfg)
    check "Unknown" in r.response or "unknown" in r.response

  # ── !config show ─────────────────────────────────────────────────────

  test "!config show displays sanitized config (no tokens)":
    var cfg = makeAdminConfig()
    cfg.tokenEnv = "MY_SECRET_TOKEN"
    let r = handleCommand("config", "show", "admin1", cfg)
    check r.response.len > 0
    check "MY_SECRET_TOKEN" notin r.response
    check r.updatedConfig.isNone

  test "!config show works for non-admin users":
    let cfg = makeAdminConfig()
    let r = handleCommand("config", "show", "user1", cfg)
    check r.response.len > 0
    check r.updatedConfig.isNone

  # ── !config set ──────────────────────────────────────────────────────

  test "!config set requires admin":
    let cfg = makeAdminConfig()
    let r = handleCommand("config", "set prefix ?", "user1", cfg)
    check "admin" in r.response.toLowerAscii or "permission" in r.response.toLowerAscii or "denied" in r.response.toLowerAscii
    check r.updatedConfig.isNone

  test "!config set prefix updates config":
    let cfg = makeAdminConfig()
    let r = handleCommand("config", "set prefix ?", "admin1", cfg)
    check r.updatedConfig.isSome
    if r.updatedConfig.isSome:
      check r.updatedConfig.get().prefix == "?"
    check "prefix" in r.response.toLowerAscii

  test "!config set with missing value returns error":
    let cfg = makeAdminConfig()
    let r = handleCommand("config", "set prefix", "admin1", cfg)
    check r.updatedConfig.isNone

  test "!config set with unknown key returns error":
    let cfg = makeAdminConfig()
    let r = handleCommand("config", "set unknownkey value", "admin1", cfg)
    check r.updatedConfig.isNone

  # ── !config reload ───────────────────────────────────────────────────

  test "!config reload requires admin":
    let cfg = makeAdminConfig()
    let r = handleCommand("config", "reload", "user1", cfg)
    check "admin" in r.response.toLowerAscii or "permission" in r.response.toLowerAscii or "denied" in r.response.toLowerAscii
    check r.updatedConfig.isNone

  test "!config reload returns placeholder response for admin":
    let cfg = makeAdminConfig()
    let r = handleCommand("config", "reload", "admin1", cfg)
    # Reload doesn't actually reload from disk in this module; it signals intent
    check "reload" in r.response.toLowerAscii
    check r.updatedConfig.isNone

  # ── !config allowlist ────────────────────────────────────────────────

  test "!config allowlist add requires admin":
    let cfg = makeAdminConfig()
    let r = handleCommand("config", "allowlist add /tmp/test", "user1", cfg)
    check "admin" in r.response.toLowerAscii or "permission" in r.response.toLowerAscii or "denied" in r.response.toLowerAscii
    check r.updatedConfig.isNone

  test "!config allowlist add adds path to fileRules.allow":
    let cfg = makeAdminConfig()
    let r = handleCommand("config", "allowlist add /tmp/test", "admin1", cfg)
    check r.updatedConfig.isSome
    check "/tmp/test" in r.updatedConfig.get().fileRules.allow

  test "!config allowlist add duplicate path does not add again":
    var cfg = makeAdminConfig()
    cfg.fileRules.allow.add("/tmp/test")
    let r = handleCommand("config", "allowlist add /tmp/test", "admin1", cfg)
    check r.updatedConfig.isSome
    let allowList = r.updatedConfig.get().fileRules.allow
    var count = 0
    for p in allowList:
      if p == "/tmp/test": count.inc
    check count == 1

  test "!config allowlist remove removes path from fileRules.allow":
    var cfg = makeAdminConfig()
    cfg.fileRules.allow = @["/tmp/test", "/home/user/docs"]
    let r = handleCommand("config", "allowlist remove /tmp/test", "admin1", cfg)
    check r.updatedConfig.isSome
    check "/tmp/test" notin r.updatedConfig.get().fileRules.allow
    check "/home/user/docs" in r.updatedConfig.get().fileRules.allow

  test "!config allowlist remove requires admin":
    let cfg = makeAdminConfig()
    let r = handleCommand("config", "allowlist remove /tmp/test", "user1", cfg)
    check "admin" in r.response.toLowerAscii or "permission" in r.response.toLowerAscii or "denied" in r.response.toLowerAscii
    check r.updatedConfig.isNone

  test "!config allowlist list shows allowed paths":
    var cfg = makeAdminConfig()
    cfg.fileRules.allow = @["/tmp/test", "/home/user/docs"]
    let r = handleCommand("config", "allowlist list", "user1", cfg)
    check "/tmp/test" in r.response
    check "/home/user/docs" in r.response
    check r.updatedConfig.isNone

  test "!config allowlist list shows message when empty":
    let cfg = makeAdminConfig()
    let r = handleCommand("config", "allowlist list", "user1", cfg)
    check r.response.len > 0
    check r.updatedConfig.isNone

  # ── !status ──────────────────────────────────────────────────────────

  test "!status returns bot status info":
    let cfg = makeAdminConfig()
    let r = handleCommand("status", "", "user1", cfg)
    check r.response.len > 0
    check r.updatedConfig.isNone

  # ── !admin ────────────────────────────────────────────────────────────

  test "!admin restart requires admin":
    let cfg = makeAdminConfig()
    let r = handleCommand("admin", "restart", "user1", cfg)
    check "admin" in r.response.toLowerAscii or "permission" in r.response.toLowerAscii or "denied" in r.response.toLowerAscii
    check r.updatedConfig.isNone

  test "!admin restart returns placeholder for admin":
    let cfg = makeAdminConfig()
    let r = handleCommand("admin", "restart", "admin1", cfg)
    check "restart" in r.response.toLowerAscii
    check r.updatedConfig.isNone

  test "!admin reconnect requires admin":
    let cfg = makeAdminConfig()
    let r = handleCommand("admin", "reconnect", "user1", cfg)
    check "admin" in r.response.toLowerAscii or "permission" in r.response.toLowerAscii or "denied" in r.response.toLowerAscii
    check r.updatedConfig.isNone

  test "!admin reconnect returns placeholder for admin":
    let cfg = makeAdminConfig()
    let r = handleCommand("admin", "reconnect", "admin1", cfg)
    check "reconnect" in r.response.toLowerAscii
    check r.updatedConfig.isNone

  test "!admin unknown subcommand":
    let cfg = makeAdminConfig()
    let r = handleCommand("admin", "unknown", "admin1", cfg)
    check "unknown" in r.response.toLowerAscii or "invalid" in r.response.toLowerAscii

  # ── !session ─────────────────────────────────────────────────────────

  test "!session list returns session info":
    let cfg = makeAdminConfig()
    let r = handleCommand("session", "list", "user1", cfg)
    check r.response.len > 0
    check r.updatedConfig.isNone

  test "!session info requires session id":
    let cfg = makeAdminConfig()
    let r = handleCommand("session", "info", "user1", cfg)
    check r.response.len > 0
    # Should indicate missing session ID
    check r.updatedConfig.isNone

  test "!session info with id returns session details":
    let cfg = makeAdminConfig()
    let r = handleCommand("session", "info sess_123", "user1", cfg)
    check "sess_123" in r.response
    check r.updatedConfig.isNone

  test "!session clear requires admin":
    let cfg = makeAdminConfig()
    let r = handleCommand("session", "clear sess_123", "user1", cfg)
    check "admin" in r.response.toLowerAscii or "permission" in r.response.toLowerAscii or "denied" in r.response.toLowerAscii
    check r.updatedConfig.isNone

  test "!session clear with id returns placeholder for admin":
    let cfg = makeAdminConfig()
    let r = handleCommand("session", "clear sess_123", "admin1", cfg)
    check "sess_123" in r.response
    check r.updatedConfig.isNone

  test "!session clear requires session id":
    let cfg = makeAdminConfig()
    let r = handleCommand("session", "clear", "admin1", cfg)
    check r.response.len > 0
    # Should indicate missing session ID

  test "!session unknown subcommand":
    let cfg = makeAdminConfig()
    let r = handleCommand("session", "unknown", "user1", cfg)
    check "unknown" in r.response.toLowerAscii or "invalid" in r.response.toLowerAscii