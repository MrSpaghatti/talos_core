# Discord Integration

Talos features a complete, DI-based Discord integration that bridges the `AgentDispatcher` with Dimscord. The bot listens for mentions and commands, routes conversations into threads, and maintains session continuity using SQLite.

## Configuration

The bot uses the layered configuration system (`config.nim`). Configuration is defined under the `[discord]` section in TOML (or `DISCORD_` prefix in `.env`).

```toml
[discord]
# The environment variable holding the Discord token (default: DISCORD_BOT_TOKEN)
token_env = "DISCORD_BOT_TOKEN"
# Command prefix for bot commands (default: !)
prefix = "!"

[discord.admins]
# List of Discord user IDs who have admin privileges
allow = ["1234567890"]
deny = []

[discord.users]
# List of Discord user IDs allowed to interact with the bot
# If empty, all users can interact (subject to other limits)
allow = []
deny = []

[discord.file_rules]
# File access rules for the read/write tools
allow = ["src/*", "docs/*"]
deny = [".env*", "*.key", ".git/*"]

[discord.tools]
# Control which users can use which tools
allow = []
deny = []
```

## Permission Model

The permission model is evaluated at two levels:
1. **Bot Interaction (`discord.users`)**: Controls who can send messages to the bot and mention it.
2. **Bot Administration (`discord.admins`)**: Controls who can use administrative commands (like `!config`, `!admin`).
3. **Tool Usage (`discord.tools`)**: Restricts certain tools (like `file_write`) to specific users. Some paths require admin approval (`pathAsk`).

## File Tool Configuration

The File Tool uses `discord.file_rules` to determine access:
- **allow**: Paths the bot can read/write without restriction.
- **ask**: Paths the bot must ask for permission (currently acts as deny for automated processes without approval).
- **deny**: Paths that are strictly forbidden. There are mandatory deny rules for credentials (`.env`, `.ssh`, etc.).

## Bot Commands Reference

Commands can be invoked in channels where the bot is present using the configured prefix (`!` by default).

### `!status`
Available to: All allowed users
Shows the bot's current status, uptime, loaded config paths, and active admins.

### `!config`
Available to: Admins only
- `!config show`: Dumps the current parsed configuration.
- `!config set <key> <value>`: Updates a configuration value in memory.
- `!config reload`: Reloads the configuration from disk.
- `!config allowlist <add|remove|list> [path]`: Manages the dynamic file allowlist in memory.

### `!admin`
Available to: Admins only
- `!admin restart`: Restarts the bot process.
- `!admin reconnect`: Forces the Dimscord gateway to reconnect.

### `!session`
Available to: All allowed users
Manage the current agent session.

## Running the Daemon

To run the Talos Discord bot, use the `daemon` command in the CLI:

```bash
export DISCORD_BOT_TOKEN="your_token_here"
talos daemon
```

This will initialize the database, load the configuration, and connect to Discord via the Gateway.

## Local Testing Instructions

The Discord integration is built using Dependency Injection. `talos_core/discord.nim` depends on callback procs for API actions rather than raw Dimscord endpoints.

To run the End-to-End Discord tests locally:

```bash
cd talos_core
nim c -r tests/test_e2e_discord.nim
```

The E2E test uses `MockDiscordApi` and `MockShard` to completely simulate Discord's HTTP and Gateway interfaces, allowing full coverage of session routing, thread creation, permission checks, and file tools without making real network requests.

### Test Suite

All Discord-related tests live in `talos_core/tests/`:

| Test file | Tests | What it covers |
|-----------|-------|----------------|
| `test_discord_mocks.nim` | Mock API and shard | Verifies mock objects correctly simulate Discord behavior |
| `test_discord_commands.nim` | Command handlers | `!status`, `!config`, `!admin`, `!session` parsing + execution |
| `test_discord_bot.nim` | Bot integration | `onMessageCreate` routing, DI wiring, permission checks |
| `test_discord_config.nim` | Discord config parsing | TOML → DiscordConfig, env var overrides, validation |
| `test_e2e_discord.nim` | End-to-end flow | Full session: message → permission → agent dispatch → response |
| `test_file_tool.nim` | File read/write tools | Path validation, traversal protection, allow/deny patterns |
| `test_file_path_validator.nim` | Path safety | Canonicalization, percent-decode, deny-list matching |
| `test_message_chunker.nim` | Message splitting | 2000-char Discord limit handling, boundary splits |
| `test_permission.nim` | Permission evaluation | User allow/deny, tool risk levels, admin checks |
| `test_rate_limit.nim` | Token-bucket rate limiter | Per-user limits, burst handling |
| `test_thread_mapping.nim` | Thread persistence | SQLite-backed channel→thread mapping |

### Architecture

```
Discord Gateway ──▶ dimscord ──▶ onMessageCreate(event)
                                    │
                                    ▼
                            discord_commands.nim
                              (parse prefix + command)
                                    │
                          ┌─────────┴──────────┐
                          ▼                     ▼
                    Admin command         Agent message
                    (!config, !admin)      (mention / DM)
                          │                     │
                          ▼                     ▼
                    Execute handler     agent_dispatcher.nim
                                          (async queue)
                                                │
                                                ▼
                                          agent_loop.nim
                                          (ReAct loop)
                                                │
                                                ▼
                                          sendFn callback
                                          (chunkMessage → reply)
```

### Module Reference

| Module | Location | Purpose |
|--------|----------|---------|
| `discord.nim` | `talos_core/discord.nim` | `DiscordBot` ref object with DI callbacks, `onMessageCreate` handler |
| `discord_bridge.nim` | `talos_core/discord_bridge.nim` | `RealDiscordApi` — wraps dimscord REST API |
| `discord_commands.nim` | `talos_core/discord_commands.nim` | Command parsing + handler dispatch |
| `discord_types.nim` | `talos_core/discord_types.nim` | `DiscordConfig`, `DiscordUser`, `FileRules` types |
| `discord_mocks.nim` | `talos_core/discord_mocks.nim` | `MockDiscordApi`, `MockShard` for offline testing |
| `agent_dispatcher.nim` | `talos_core/agent_dispatcher.nim` | `AgentDispatcher` — async agent request queue with callback |
| `permission.nim` | `talos_core/permission.nim` | `PermissionEvaluator` — user/tool/path permission model |
| `file_path_validator.nim` | `talos_core/file_path_validator.nim` | Path canonicalization + security validation |
| `file_tool.nim` | `talos_core/file_tool.nim` | `fileReadTool`, `fileWriteTool` — sandboxed file operations |
| `message_chunker.nim` | `talos_core/message_chunker.nim` | Splits messages at 2000-char Discord limit |
| `rate_limit.nim` | `talos_core/rate_limit.nim` | Per-user token-bucket rate limiter |
| `thread_mapping.nim` | `talos_core/thread_mapping.nim` | Persistent channel↔thread mapping with SQLite |