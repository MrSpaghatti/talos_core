## Tests for Discord config parsing

import std/[os, unittest, strutils]
import talos_core/config
import talos_core/discord_types

proc writeTempFile(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

suite "Discord Config Defaults":
  test "default discord config has expected values":
    let cfg = defaultConfig()
    check cfg.discord.tokenEnv == "DISCORD_BOT_TOKEN"
    check cfg.discord.prefix == "!"
    check cfg.discord.admins.allow.len == 0
    check cfg.discord.admins.deny.len == 0
    check cfg.discord.users.allow.len == 0
    check cfg.discord.users.deny.len == 0
    check cfg.discord.fileRules.allow.len == 0
    check cfg.discord.fileRules.deny == @[".env", ".ssh", ".aws", ".gnupg", "*.key", "*.pem"]
    check cfg.discord.tools.allow.len == 0
    check cfg.discord.tools.deny.len == 0

suite "Discord Config Parsing":
  let tmpDir = getTempDir() / "talos_test_discord_toml"

  setup:
    createDir(tmpDir)

  teardown:
    removeDir(tmpDir)

  test "parses basic [discord] section":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, """
[discord]
token_env = "MY_CUSTOM_TOKEN"
prefix = "?"
""")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.discord.tokenEnv == "MY_CUSTOM_TOKEN"
    check cfg.discord.prefix == "?"

  test "parses [discord.admins] access control":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, """
[discord.admins]
allow = "123, 456"
deny = "789"
""")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.discord.admins.allow == @["123", "456"]
    check cfg.discord.admins.deny == @["789"]

  test "parses [discord.file_rules] with comma separated lists":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, """
[discord.file_rules]
allow = "*.txt, *.md"
deny = ".env, secret.key"
""")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.discord.fileRules.allow == @["*.txt", "*.md"]
    check cfg.discord.fileRules.deny == @[".env", "secret.key"]
