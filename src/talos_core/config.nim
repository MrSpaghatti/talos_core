## Talos configuration module.
##
## Loads configuration from:
## 1. Built-in defaults
## 2. TOML config file at ~/.config/talos/config.toml
## 3. .env file in the current working directory (API keys)
## 4. Environment variables (highest priority)
##
## Supported environment variable overrides:
##   TALOS_PROVIDER, TALOS_VLLM_ENDPOINT, TALOS_OPENROUTER_ENDPOINT,
##   TALOS_OPENROUTER_MODEL, TALOS_VLLM_MODEL, TALOS_MAX_TOKENS,
##   TALOS_TEMPERATURE, TALOS_MAX_LOOP_ITERATIONS, TALOS_DB_PATH,
##   OPENROUTER_API_KEY

import std/[os, parsecfg, strutils, streams]
import discord_types

type
  McpServerConfig* = object
    ## Configuration for a single MCP server endpoint.
    name*: string          ## Human-readable name from TOML section (e.g. "filesystem")
    url*: string
    authToken*: string
    timeoutMs*: int
    enabled*: bool

  TalosConfig* = object
    provider*: string           ## "openrouter" or "vllm"
    vllmEndpoint*: string
    openrouterEndpoint*: string
    openrouterModel*: string
    vllmModel*: string
    maxTokens*: int
    temperature*: float
    maxLoopIterations*: int
    dbPath*: string
    openrouterApiKey*: string   ## loaded from .env or env var
    webPort*: int               ## web UI listen port
    discord*: DiscordConfig
    mcpServers*: seq[McpServerConfig]  ## Configured MCP server endpoints

  ConfigError* = object of CatchableError

const
  DefaultProvider* = "openrouter"
  DefaultVllmEndpoint* = "http://192.168.4.30:8000/v1"
  DefaultOpenrouterEndpoint* = "https://openrouter.ai/api/v1"
  DefaultOpenrouterModel* = "openrouter/auto"
  DefaultVllmModel* = "qwen2.5-7b-instruct"
  DefaultMaxTokens* = 4096
  DefaultTemperature* = 0.3
  DefaultMaxLoopIterations* = 10
  DefaultMcpTimeoutMs* = 30_000
  DefaultDbPath* = "~/.local/share/talos/talos.db"
  DefaultWebPort* = 8080

proc defaultConfig*(): TalosConfig =
  ## Returns a TalosConfig populated with all defaults.
  TalosConfig(
    provider: DefaultProvider,
    vllmEndpoint: DefaultVllmEndpoint,
    openrouterEndpoint: DefaultOpenrouterEndpoint,
    openrouterModel: DefaultOpenrouterModel,
    vllmModel: DefaultVllmModel,
    maxTokens: DefaultMaxTokens,
    temperature: DefaultTemperature,
    maxLoopIterations: DefaultMaxLoopIterations,
    dbPath: DefaultDbPath,
    openrouterApiKey: "",
    webPort: DefaultWebPort,
    discord: defaultDiscordConfig(),
    mcpServers: @[],
  )

proc parseEnvFile*(path: string): seq[tuple[key, val: string]] =
  ## Parses a .env file and returns key-value pairs.
  ## Lines starting with '#' are comments. Blank lines are skipped.
  ## Values may optionally be quoted with single or double quotes.
  result = @[]
  if not fileExists(path):
    return
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    let eqPos = trimmed.find('=')
    if eqPos < 1:
      continue
    let key = trimmed[0 ..< eqPos].strip()
    var val = trimmed[eqPos + 1 .. ^1].strip()
    # Strip optional surrounding quotes
    if val.len >= 2:
      if (val[0] == '"' and val[^1] == '"') or
         (val[0] == '\'' and val[^1] == '\''):
        val = val[1 ..< val.len - 1]
    result.add((key, val))

proc parseCsvList(val: string): seq[string] =
  result = @[]
  for item in val.split(','):
    let stripped = item.strip()
    if stripped.len > 0:
      result.add(stripped)

# ---------------------------------------------------------------------------
# MCP server config parsing (TOML and env)
# ---------------------------------------------------------------------------

type
  McpServerEntry* = object
    ## Temporary storage for a single [mcp_servers.name] block during TOML
    ## parsing. Fields that are not set in the TOML remain as empty/zero
    ## defaults and are filled in by `parseMcpServerEntry()` at the end.
    name*: string
    url*: string
    authToken*: string
    timeoutMs*: int
    enabledExplicit*: bool  ## true if "enabled" was explicitly set in TOML/env
    enabled*: bool          ## the value (true unless explicitly set to false)

proc parseMcpServerEntry(entry: McpServerEntry): McpServerConfig =
  ## Converts a parsed `McpServerEntry` into a `McpServerConfig`, filling in
  ## any missing values with defaults. Strips trailing slashes from URL.
  let name =
    if entry.name.startsWith("mcp_servers."):
      entry.name[12 .. ^1]  # strip "mcp_servers." prefix
    else:
      entry.name
  result = McpServerConfig(
    name: name,
    url: if entry.url.len > 0: entry.url.strip(trailing = true, chars = {'/'})
         else: "http://localhost:8080/mcp",
    authToken: entry.authToken,
    timeoutMs: if entry.timeoutMs > 0: entry.timeoutMs else: DefaultMcpTimeoutMs,
    enabled: if entry.enabledExplicit: entry.enabled else: true,
  )

proc applyEnvMcpServers*(cfg: var TalosConfig) =
  ## Applies MCP server configuration from environment variables.
  ##
  ## Format: TALOS_MCP_SERVER_<N>_URL, TALOS_MCP_SERVER_<N>_AUTH_TOKEN,
  ##          TALOS_MCP_SERVER_<N>_TIMEOUT_MS, TALOS_MCP_SERVER_<N>_ENABLED
  ## where <N> is a zero-based index. Stop at first gap in sequence.
  ## Falls back to MERCURY_MCP_SERVER_* with deprecation warning.
  ##
  ## Example:
  ##   TALOS_MCP_SERVER_0_URL=http://localhost:8080/mcp
  ##   TALOS_MCP_SERVER_0_AUTH_TOKEN=secret123
  ##   TALOS_MCP_SERVER_1_URL=https://mcp.example.com
  var i = 0
  while true:
    let urlEnv = "TALOS_MCP_SERVER_" & $i & "_URL"
    var url = getEnv(urlEnv)
    if url.len == 0:
      let oldUrlEnv = "MERCURY_MCP_SERVER_" & $i & "_URL"
      url = getEnv(oldUrlEnv)
      if url.len > 0:
        stderr.writeLine("Warning: " & oldUrlEnv & " is deprecated, use " & urlEnv & " instead")
    if url.len == 0:
      break  # No more servers configured
    var entry = McpServerEntry(name: $i, url: url)
    
    let authEnv = "TALOS_MCP_SERVER_" & $i & "_AUTH_TOKEN"
    var auth = getEnv(authEnv)
    if auth.len == 0:
      let oldAuthEnv = "MERCURY_MCP_SERVER_" & $i & "_AUTH_TOKEN"
      auth = getEnv(oldAuthEnv)
      if auth.len > 0:
        stderr.writeLine("Warning: " & oldAuthEnv & " is deprecated, use " & authEnv & " instead")
    if auth.len > 0:
      entry.authToken = auth
    
    let timeoutEnv = "TALOS_MCP_SERVER_" & $i & "_TIMEOUT_MS"
    var timeoutStr = getEnv(timeoutEnv)
    if timeoutStr.len == 0:
      let oldTimeoutEnv = "MERCURY_MCP_SERVER_" & $i & "_TIMEOUT_MS"
      timeoutStr = getEnv(oldTimeoutEnv)
      if timeoutStr.len > 0:
        stderr.writeLine("Warning: " & oldTimeoutEnv & " is deprecated, use " & timeoutEnv & " instead")
    if timeoutStr.len > 0:
      try:
        entry.timeoutMs = parseInt(timeoutStr)
      except ValueError:
        raise newException(ConfigError,
          timeoutEnv & " must be an integer, got: " & timeoutStr)
    
    let enabledEnv = "TALOS_MCP_SERVER_" & $i & "_ENABLED"
    var enabledStr = getEnv(enabledEnv)
    if enabledStr.len == 0:
      let oldEnabledEnv = "MERCURY_MCP_SERVER_" & $i & "_ENABLED"
      enabledStr = getEnv(oldEnabledEnv)
      if enabledStr.len > 0:
        stderr.writeLine("Warning: " & oldEnabledEnv & " is deprecated, use " & enabledEnv & " instead")
    if enabledStr.len > 0:
      entry.enabled = enabledStr.toLowerAscii() in @["1", "true", "yes", "on"]
      entry.enabledExplicit = true
    cfg.mcpServers.add(parseMcpServerEntry(entry))
    inc i
proc applyTomlSection(cfg: var TalosConfig; section, key, val: string) =
  ## Applies a single key-value pair from the TOML/INI config to cfg.
  ## Section "" means the global/root section.
  let k = key.toLowerAscii()
  case section.toLowerAscii()
  of "", "talos", "mercury":
    case k
    of "provider":           cfg.provider = val
    of "vllm_endpoint":      cfg.vllmEndpoint = val
    of "openrouter_endpoint": cfg.openrouterEndpoint = val
    of "openrouter_model":   cfg.openrouterModel = val
    of "vllm_model":         cfg.vllmModel = val
    of "max_tokens":
      let n = parseInt(val)
      cfg.maxTokens = n
    of "temperature":
      let f = parseFloat(val)
      cfg.temperature = f
    of "max_loop_iterations":
      let n = parseInt(val)
      cfg.maxLoopIterations = n
    of "db_path":            cfg.dbPath = val
    of "web_port":
      let n = parseInt(val)
      cfg.webPort = n
    else: discard
  of "discord":
    case k
    of "token_env": cfg.discord.tokenEnv = val
    of "prefix": cfg.discord.prefix = val
    else: discard
  of "discord.admins":
    case k
    of "allow": cfg.discord.admins.allow = parseCsvList(val)
    of "deny": cfg.discord.admins.deny = parseCsvList(val)
    else: discard
  of "discord.users":
    case k
    of "allow": cfg.discord.users.allow = parseCsvList(val)
    of "deny": cfg.discord.users.deny = parseCsvList(val)
    else: discard
  of "discord.file_rules":
    case k
    of "allow": cfg.discord.fileRules.allow = parseCsvList(val)
    of "deny": cfg.discord.fileRules.deny = parseCsvList(val)
    else: discard
  of "discord.tools":
    case k
    of "allow": cfg.discord.tools.allow = parseCsvList(val)
    of "deny": cfg.discord.tools.deny = parseCsvList(val)
    else: discard
  else: discard

proc loadTomlFile(cfg: var TalosConfig; path: string) =
  ## Loads config values from a TOML/INI file, overriding defaults.
  if not fileExists(path):
    return
  var stream = newFileStream(path, fmRead)
  if stream == nil:
    raise newException(ConfigError, "Cannot open config file: " & path)
  defer: stream.close()
  var parser: CfgParser
  open(parser, stream, path)
  defer: close(parser)

  # Accumulators for [mcp_servers.<name>] blocks.
  # We can't use applyTomlSection because it handles one key-value at a time
  # and we need to collect all fields for a given server before creating the
  # McpServerConfig. Parsed here, applied at EOF.
  var mcpEntries: seq[McpServerEntry] = @[]
  var currentMcpServer = ""
  var mcpBuf = McpServerEntry()

  var currentSection = ""
  while true:
    let event = next(parser)
    case event.kind
    of cfgEof:
      break
    of cfgSectionStart:
      # New section — flush any pending MCP server entry first.
      if currentMcpServer.len > 0 and mcpBuf.name.len > 0:
        mcpEntries.add(mcpBuf)

      currentSection = event.section
      let sec = currentSection.toLowerAscii()
      if sec.startsWith("mcp_servers."):
        currentMcpServer = sec
        mcpBuf = McpServerEntry(name: sec)
      else:
        currentMcpServer = ""
    of cfgKeyValuePair:
      if currentMcpServer.len > 0:
        # Inside a [mcp_servers.<name>] block — accumulate into mcpBuf.
        let k = event.key.toLowerAscii()
        case k
        of "url":          mcpBuf.url = event.value
        of "auth_token":   mcpBuf.authToken = event.value
        of "timeout_ms":
          try:
            mcpBuf.timeoutMs = parseInt(event.value)
          except ValueError:
            raise newException(ConfigError,
              "Invalid timeout_ms in " & path & ": " & event.value)
        of "enabled":
          mcpBuf.enabled = event.value.toLowerAscii() in @["1", "true", "yes", "on"]
          mcpBuf.enabledExplicit = true
        else: discard
      else:
        try:
          applyTomlSection(cfg, currentSection, event.key, event.value)
        except ValueError as e:
          raise newException(ConfigError,
            "Invalid value for key '" & event.key & "' in " & path & ": " & e.msg)
    of cfgOption:
      discard
    of cfgError:
      raise newException(ConfigError,
        "Parse error in " & path & ": " & event.msg)

  # Flush any remaining MCP server entry.
  if currentMcpServer.len > 0 and mcpBuf.name.len > 0:
    mcpEntries.add(mcpBuf)

  # Apply all collected MCP server entries.
  for entry in mcpEntries:
    cfg.mcpServers.add(parseMcpServerEntry(entry))

proc applyEnvVars(cfg: var TalosConfig) =
  ## Applies environment variable overrides to cfg.
  ## Checks TALOS_* variables first, then falls back to MERCURY_* with deprecation warning.
  
  let provider = getEnv("TALOS_PROVIDER")
  if provider.len > 0:
    cfg.provider = provider
  else:
    let oldProvider = getEnv("MERCURY_PROVIDER")
    if oldProvider.len > 0:
      stderr.writeLine("Warning: MERCURY_PROVIDER is deprecated, use TALOS_PROVIDER instead")
      cfg.provider = oldProvider

  let vllmEndpoint = getEnv("TALOS_VLLM_ENDPOINT")
  if vllmEndpoint.len > 0:
    cfg.vllmEndpoint = vllmEndpoint
  else:
    let oldVllmEndpoint = getEnv("MERCURY_VLLM_ENDPOINT")
    if oldVllmEndpoint.len > 0:
      stderr.writeLine("Warning: MERCURY_VLLM_ENDPOINT is deprecated, use TALOS_VLLM_ENDPOINT instead")
      cfg.vllmEndpoint = oldVllmEndpoint

  let orEndpoint = getEnv("TALOS_OPENROUTER_ENDPOINT")
  if orEndpoint.len > 0:
    cfg.openrouterEndpoint = orEndpoint
  else:
    let oldOrEndpoint = getEnv("MERCURY_OPENROUTER_ENDPOINT")
    if oldOrEndpoint.len > 0:
      stderr.writeLine("Warning: MERCURY_OPENROUTER_ENDPOINT is deprecated, use TALOS_OPENROUTER_ENDPOINT instead")
      cfg.openrouterEndpoint = oldOrEndpoint

  let orModel = getEnv("TALOS_OPENROUTER_MODEL")
  if orModel.len > 0:
    cfg.openrouterModel = orModel
  else:
    let oldOrModel = getEnv("MERCURY_OPENROUTER_MODEL")
    if oldOrModel.len > 0:
      stderr.writeLine("Warning: MERCURY_OPENROUTER_MODEL is deprecated, use TALOS_OPENROUTER_MODEL instead")
      cfg.openrouterModel = oldOrModel

  let vllmModel = getEnv("TALOS_VLLM_MODEL")
  if vllmModel.len > 0:
    cfg.vllmModel = vllmModel
  else:
    let oldVllmModel = getEnv("MERCURY_VLLM_MODEL")
    if oldVllmModel.len > 0:
      stderr.writeLine("Warning: MERCURY_VLLM_MODEL is deprecated, use TALOS_VLLM_MODEL instead")
      cfg.vllmModel = oldVllmModel

  let maxTokensStr = getEnv("TALOS_MAX_TOKENS")
  if maxTokensStr.len > 0:
    try:
      cfg.maxTokens = parseInt(maxTokensStr)
    except ValueError:
      raise newException(ConfigError,
        "TALOS_MAX_TOKENS must be an integer, got: " & maxTokensStr)
  else:
    let oldMaxTokensStr = getEnv("MERCURY_MAX_TOKENS")
    if oldMaxTokensStr.len > 0:
      stderr.writeLine("Warning: MERCURY_MAX_TOKENS is deprecated, use TALOS_MAX_TOKENS instead")
      try:
        cfg.maxTokens = parseInt(oldMaxTokensStr)
      except ValueError:
        raise newException(ConfigError,
          "MERCURY_MAX_TOKENS must be an integer, got: " & oldMaxTokensStr)

  let tempStr = getEnv("TALOS_TEMPERATURE")
  if tempStr.len > 0:
    try:
      cfg.temperature = parseFloat(tempStr)
    except ValueError:
      raise newException(ConfigError,
        "TALOS_TEMPERATURE must be a float, got: " & tempStr)
  else:
    let oldTempStr = getEnv("MERCURY_TEMPERATURE")
    if oldTempStr.len > 0:
      stderr.writeLine("Warning: MERCURY_TEMPERATURE is deprecated, use TALOS_TEMPERATURE instead")
      try:
        cfg.temperature = parseFloat(oldTempStr)
      except ValueError:
        raise newException(ConfigError,
          "MERCURY_TEMPERATURE must be a float, got: " & oldTempStr)

  let maxLoopStr = getEnv("TALOS_MAX_LOOP_ITERATIONS")
  if maxLoopStr.len > 0:
    try:
      cfg.maxLoopIterations = parseInt(maxLoopStr)
    except ValueError:
      raise newException(ConfigError,
        "TALOS_MAX_LOOP_ITERATIONS must be an integer, got: " & maxLoopStr)
  else:
    let oldMaxLoopStr = getEnv("MERCURY_MAX_LOOP_ITERATIONS")
    if oldMaxLoopStr.len > 0:
      stderr.writeLine("Warning: MERCURY_MAX_LOOP_ITERATIONS is deprecated, use TALOS_MAX_LOOP_ITERATIONS instead")
      try:
        cfg.maxLoopIterations = parseInt(oldMaxLoopStr)
      except ValueError:
        raise newException(ConfigError,
          "MERCURY_MAX_LOOP_ITERATIONS must be an integer, got: " & oldMaxLoopStr)

  let dbPath = getEnv("TALOS_DB_PATH")
  if dbPath.len > 0:
    cfg.dbPath = dbPath
  else:
    let oldDbPath = getEnv("MERCURY_DB_PATH")
    if oldDbPath.len > 0:
      stderr.writeLine("Warning: MERCURY_DB_PATH is deprecated, use TALOS_DB_PATH instead")
      cfg.dbPath = oldDbPath

  let apiKey = getEnv("OPENROUTER_API_KEY")
  if apiKey.len > 0:
    cfg.openrouterApiKey = apiKey

  let webPortStr = getEnv("TALOS_WEB_PORT")
  if webPortStr.len > 0:
    try:
      cfg.webPort = parseInt(webPortStr)
    except ValueError:
      raise newException(ConfigError,
        "TALOS_WEB_PORT must be an integer, got: " & webPortStr)
  else:
    let oldWebPortStr = getEnv("MERCURY_WEB_PORT")
    if oldWebPortStr.len > 0:
      stderr.writeLine("Warning: MERCURY_WEB_PORT is deprecated, use TALOS_WEB_PORT instead")
      try:
        cfg.webPort = parseInt(oldWebPortStr)
      except ValueError:
        raise newException(ConfigError,
          "MERCURY_WEB_PORT must be an integer, got: " & oldWebPortStr)

  # Apply MCP server configuration from environment variables.
  applyEnvMcpServers(cfg)

proc validate*(cfg: TalosConfig) =
  ## Validates the configuration, raising ConfigError on invalid values.
  if cfg.provider != "openrouter" and cfg.provider != "vllm":
    raise newException(ConfigError,
      "provider must be 'openrouter' or 'vllm', got: '" & cfg.provider & "'")
  if cfg.maxTokens <= 0:
    raise newException(ConfigError,
      "max_tokens must be positive, got: " & $cfg.maxTokens)
  if cfg.temperature < 0.0 or cfg.temperature > 2.0:
    raise newException(ConfigError,
      "temperature must be between 0.0 and 2.0, got: " & $cfg.temperature)
  if cfg.maxLoopIterations <= 0:
    raise newException(ConfigError,
      "max_loop_iterations must be positive, got: " & $cfg.maxLoopIterations)
  if cfg.vllmEndpoint.len == 0:
    raise newException(ConfigError, "vllm_endpoint must not be empty")
  if cfg.openrouterEndpoint.len == 0:
    raise newException(ConfigError, "openrouter_endpoint must not be empty")
  if cfg.dbPath.len == 0:
    raise newException(ConfigError, "db_path must not be empty")

  # Warn if OpenRouter is selected but no API key is configured.
  if cfg.provider == "openrouter" and cfg.openrouterApiKey.len == 0:
    stderr.writeLine("talos: warning — provider is 'openrouter' but OPENROUTER_API_KEY is empty")

proc loadConfig*(
    configPath: string = "",
    envFilePath: string = ".env"
): TalosConfig =
  ## Loads Talos configuration with the following priority (highest wins):
  ##   1. Environment variables
  ##   2. .env file (API keys)
  ##   3. TOML config file
  ##   4. Built-in defaults
  ##
  ## configPath: path to the TOML config file.
  ##   Defaults to ~/.config/talos/config.toml
  ## envFilePath: path to the .env file.
  ##   Defaults to ".env" in the current directory.
  result = defaultConfig()

  # Resolve config file path
  let cfgPath =
    if configPath.len > 0:
      configPath
    else:
      getHomeDir() / ".config" / "talos" / "config.toml"

  # Layer 2: TOML file
  loadTomlFile(result, cfgPath)

  # Layer 3: .env file (API keys and other overrides)
  let envPairs = parseEnvFile(envFilePath)
  for (key, val) in envPairs:
    case key
    of "OPENROUTER_API_KEY":
      result.openrouterApiKey = val
    of "TALOS_PROVIDER":
      result.provider = val
    of "TALOS_VLLM_ENDPOINT":
      result.vllmEndpoint = val
    of "TALOS_OPENROUTER_ENDPOINT":
      result.openrouterEndpoint = val
    of "TALOS_OPENROUTER_MODEL":
      result.openrouterModel = val
    of "TALOS_VLLM_MODEL":
      result.vllmModel = val
    of "TALOS_MAX_TOKENS":
      try:
        result.maxTokens = parseInt(val)
      except ValueError:
        discard
    of "TALOS_TEMPERATURE":
      try:
        result.temperature = parseFloat(val)
      except ValueError:
        discard
    of "TALOS_MAX_LOOP_ITERATIONS":
      try:
        result.maxLoopIterations = parseInt(val)
      except ValueError:
        discard
    of "TALOS_DB_PATH":
      result.dbPath = val
    of "TALOS_WEB_PORT":
      try:
        result.webPort = parseInt(val)
      except ValueError:
        discard
    of "MERCURY_PROVIDER":
      stderr.writeLine("Warning: MERCURY_PROVIDER in .env is deprecated, use TALOS_PROVIDER instead")
      result.provider = val
    of "MERCURY_VLLM_ENDPOINT":
      stderr.writeLine("Warning: MERCURY_VLLM_ENDPOINT in .env is deprecated, use TALOS_VLLM_ENDPOINT instead")
      result.vllmEndpoint = val
    of "MERCURY_OPENROUTER_ENDPOINT":
      stderr.writeLine("Warning: MERCURY_OPENROUTER_ENDPOINT in .env is deprecated, use TALOS_OPENROUTER_ENDPOINT instead")
      result.openrouterEndpoint = val
    of "MERCURY_OPENROUTER_MODEL":
      stderr.writeLine("Warning: MERCURY_OPENROUTER_MODEL in .env is deprecated, use TALOS_OPENROUTER_MODEL instead")
      result.openrouterModel = val
    of "MERCURY_VLLM_MODEL":
      stderr.writeLine("Warning: MERCURY_VLLM_MODEL in .env is deprecated, use TALOS_VLLM_MODEL instead")
      result.vllmModel = val
    else: discard

  # Layer 4: Environment variables (highest priority)
  applyEnvVars(result)

  validate(result)
