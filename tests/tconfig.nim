## Tests for talos_core/config.nim

import std/[os, unittest]
import talos_core/config, talos_core/mcp_client

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc writeTempFile(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

template withEnv(key, val: string; body: untyped) =
  ## Temporarily sets an environment variable, then restores the original.
  let oldVal = getEnv(key)
  let hadOldVal = existsEnv(key)
  putEnv(key, val)
  try:
    body
  finally:
    if hadOldVal:
      putEnv(key, oldVal)
    else:
      delEnv(key)

template withoutEnv(key: string; body: untyped) =
  ## Temporarily unsets an environment variable, then restores the original.
  ## Needed so .env-file precedence tests are not shadowed by an OS env var
  ## that a developer happens to have set (e.g. a real OPENROUTER_API_KEY).
  let oldVal = getEnv(key)
  let hadOldVal = existsEnv(key)
  delEnv(key)
  try:
    body
  finally:
    if hadOldVal:
      putEnv(key, oldVal)

# ---------------------------------------------------------------------------
# Suite: defaultConfig
# ---------------------------------------------------------------------------

suite "defaultConfig":
  test "returns expected defaults":
    let cfg = defaultConfig()
    check cfg.provider == "openrouter"
    check cfg.vllmEndpoint == "http://192.168.4.30:8000/v1"
    check cfg.openrouterEndpoint == "https://openrouter.ai/api/v1"
    check cfg.openrouterModel == "openrouter/auto"
    check cfg.vllmModel == "qwen2.5-7b-instruct"
    check cfg.maxTokens == 4096
    check cfg.temperature == 0.3
    check cfg.maxLoopIterations == 10
    check cfg.dbPath == "~/.local/share/talos/talos.db"
    check cfg.openrouterApiKey == ""

# ---------------------------------------------------------------------------
# Suite: parseEnvFile
# ---------------------------------------------------------------------------

suite "parseEnvFile":
  let tmpDir = getTempDir() / "talos_test_env"

  setup:
    createDir(tmpDir)

  teardown:
    removeDir(tmpDir)

  test "returns empty seq for missing file":
    let pairs = parseEnvFile(tmpDir / "nonexistent.env")
    check pairs.len == 0

  test "parses simple key=value pairs":
    let path = tmpDir / "simple.env"
    writeTempFile(path, "FOO=bar\nBAZ=qux\n")
    let pairs = parseEnvFile(path)
    check pairs.len == 2
    check pairs[0] == ("FOO", "bar")
    check pairs[1] == ("BAZ", "qux")

  test "strips double-quoted values":
    let path = tmpDir / "quoted.env"
    writeTempFile(path, "KEY=\"hello world\"\n")
    let pairs = parseEnvFile(path)
    check pairs.len == 1
    check pairs[0] == ("KEY", "hello world")

  test "strips single-quoted values":
    let path = tmpDir / "squoted.env"
    writeTempFile(path, "KEY='hello world'\n")
    let pairs = parseEnvFile(path)
    check pairs.len == 1
    check pairs[0] == ("KEY", "hello world")

  test "ignores comment lines":
    let path = tmpDir / "comments.env"
    writeTempFile(path, "# this is a comment\nKEY=val\n")
    let pairs = parseEnvFile(path)
    check pairs.len == 1
    check pairs[0] == ("KEY", "val")

  test "ignores blank lines":
    let path = tmpDir / "blanks.env"
    writeTempFile(path, "\n\nKEY=val\n\n")
    let pairs = parseEnvFile(path)
    check pairs.len == 1

  test "handles empty value":
    let path = tmpDir / "empty_val.env"
    writeTempFile(path, "KEY=\n")
    let pairs = parseEnvFile(path)
    check pairs.len == 1
    check pairs[0] == ("KEY", "")

# ---------------------------------------------------------------------------
# Suite: loadConfig — defaults when no files exist
# ---------------------------------------------------------------------------

suite "loadConfig defaults":
  test "uses defaults when config file is missing":
    let cfg = loadConfig(
      configPath = "/nonexistent/path/config.toml",
      envFilePath = "/nonexistent/.env"
    )
    check cfg.provider == "openrouter"
    check cfg.maxTokens == 4096
    check cfg.temperature == 0.3

# ---------------------------------------------------------------------------
# Suite: loadConfig — TOML file overrides
# ---------------------------------------------------------------------------

suite "loadConfig TOML overrides":
  let tmpDir = getTempDir() / "talos_test_toml"

  setup:
    createDir(tmpDir)

  teardown:
    removeDir(tmpDir)

  test "overrides provider from TOML":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, "[talos]\nprovider=vllm\n")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.provider == "vllm"

  test "overrides max_tokens from TOML":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, "[talos]\nmax_tokens=2048\n")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.maxTokens == 2048

  test "overrides temperature from TOML":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, "[talos]\ntemperature=0.7\n")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.temperature == 0.7

  test "overrides vllm_model from TOML":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, "[talos]\nvllm_model=llama3-8b\n")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.vllmModel == "llama3-8b"

  test "overrides db_path from TOML":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, "[talos]\ndb_path=/tmp/test.db\n")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.dbPath == "/tmp/test.db"

  test "overrides multiple fields from TOML":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, "[talos]\nprovider=vllm\nmax_tokens=1024\nmax_loop_iterations=5\n")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.provider == "vllm"
    check cfg.maxTokens == 1024
    check cfg.maxLoopIterations == 5

  test "raises ConfigError on invalid max_tokens":
    let cfgFile = tmpDir / "bad.toml"
    writeTempFile(cfgFile, "[talos]\nmax_tokens=notanumber\n")
    expect ConfigError:
      discard loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")

# ---------------------------------------------------------------------------
# Suite: loadConfig — .env file overrides
# ---------------------------------------------------------------------------

suite "loadConfig .env overrides":
  let tmpDir = getTempDir() / "talos_test_dotenv"

  setup:
    createDir(tmpDir)

  teardown:
    removeDir(tmpDir)

  test "loads OPENROUTER_API_KEY from .env":
    withoutEnv("OPENROUTER_API_KEY"):
      let envFile = tmpDir / ".env"
      writeTempFile(envFile, "OPENROUTER_API_KEY=sk-test-key\n")
      let cfg = loadConfig(
        configPath = "/nonexistent/config.toml",
        envFilePath = envFile
      )
      check cfg.openrouterApiKey == "sk-test-key"

  test "loads TALOS_PROVIDER from .env":
    withoutEnv("TALOS_PROVIDER"):
      let envFile = tmpDir / ".env"
      writeTempFile(envFile, "TALOS_PROVIDER=vllm\n")
      let cfg = loadConfig(
        configPath = "/nonexistent/config.toml",
        envFilePath = envFile
      )
      check cfg.provider == "vllm"

  test "loads TALOS_VLLM_ENDPOINT from .env":
    withoutEnv("TALOS_VLLM_ENDPOINT"):
      let envFile = tmpDir / ".env"
      writeTempFile(envFile, "TALOS_VLLM_ENDPOINT=http://10.0.0.1:8000/v1\n")
      let cfg = loadConfig(
        configPath = "/nonexistent/config.toml",
        envFilePath = envFile
      )
      check cfg.vllmEndpoint == "http://10.0.0.1:8000/v1"

# ---------------------------------------------------------------------------
# Suite: loadConfig — environment variable overrides
# ---------------------------------------------------------------------------

suite "loadConfig env var overrides":
  test "TALOS_PROVIDER overrides config file":
    withEnv("TALOS_PROVIDER", "vllm"):
      let cfg = loadConfig(
        configPath = "/nonexistent/config.toml",
        envFilePath = "/nonexistent/.env"
      )
      check cfg.provider == "vllm"

  test "TALOS_VLLM_ENDPOINT overrides default":
    withEnv("TALOS_VLLM_ENDPOINT", "http://custom:9000/v1"):
      let cfg = loadConfig(
        configPath = "/nonexistent/config.toml",
        envFilePath = "/nonexistent/.env"
      )
      check cfg.vllmEndpoint == "http://custom:9000/v1"

  test "TALOS_MAX_TOKENS overrides default":
    withEnv("TALOS_MAX_TOKENS", "512"):
      let cfg = loadConfig(
        configPath = "/nonexistent/config.toml",
        envFilePath = "/nonexistent/.env"
      )
      check cfg.maxTokens == 512

  test "TALOS_TEMPERATURE overrides default":
    withEnv("TALOS_TEMPERATURE", "1.0"):
      let cfg = loadConfig(
        configPath = "/nonexistent/config.toml",
        envFilePath = "/nonexistent/.env"
      )
      check cfg.temperature == 1.0

  test "TALOS_MAX_LOOP_ITERATIONS overrides default":
    withEnv("TALOS_MAX_LOOP_ITERATIONS", "3"):
      let cfg = loadConfig(
        configPath = "/nonexistent/config.toml",
        envFilePath = "/nonexistent/.env"
      )
      check cfg.maxLoopIterations == 3

  test "OPENROUTER_API_KEY overrides .env":
    withEnv("OPENROUTER_API_KEY", "env-key-override"):
      let cfg = loadConfig(
        configPath = "/nonexistent/config.toml",
        envFilePath = "/nonexistent/.env"
      )
      check cfg.openrouterApiKey == "env-key-override"

  test "env var overrides TOML file value":
    let tmpDir2 = getTempDir() / "talos_test_priority"
    createDir(tmpDir2)
    defer: removeDir(tmpDir2)
    let cfgFile = tmpDir2 / "config.toml"
    writeTempFile(cfgFile, "[talos]\nmax_tokens=2048\n")
    withEnv("TALOS_MAX_TOKENS", "999"):
      let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
      check cfg.maxTokens == 999

  test "raises ConfigError on invalid TALOS_MAX_TOKENS":
    withEnv("TALOS_MAX_TOKENS", "bad"):
      expect ConfigError:
        discard loadConfig(
          configPath = "/nonexistent/config.toml",
          envFilePath = "/nonexistent/.env"
        )

  test "raises ConfigError on invalid TALOS_TEMPERATURE":
    withEnv("TALOS_TEMPERATURE", "bad"):
      expect ConfigError:
        discard loadConfig(
          configPath = "/nonexistent/config.toml",
          envFilePath = "/nonexistent/.env"
        )

# ---------------------------------------------------------------------------
# Suite: validate
# ---------------------------------------------------------------------------

suite "validate":
  test "valid config passes":
    let cfg = defaultConfig()
    validate(cfg)  # should not raise

  test "invalid provider raises ConfigError":
    var cfg = defaultConfig()
    cfg.provider = "unknown"
    expect ConfigError:
      validate(cfg)

  test "zero max_tokens raises ConfigError":
    var cfg = defaultConfig()
    cfg.maxTokens = 0
    expect ConfigError:
      validate(cfg)

  test "negative max_tokens raises ConfigError":
    var cfg = defaultConfig()
    cfg.maxTokens = -1
    expect ConfigError:
      validate(cfg)

  test "temperature above 2.0 raises ConfigError":
    var cfg = defaultConfig()
    cfg.temperature = 2.1
    expect ConfigError:
      validate(cfg)

  test "negative temperature raises ConfigError":
    var cfg = defaultConfig()
    cfg.temperature = -0.1
    expect ConfigError:
      validate(cfg)

  test "zero max_loop_iterations raises ConfigError":
    var cfg = defaultConfig()
    cfg.maxLoopIterations = 0
    expect ConfigError:
      validate(cfg)

  test "empty vllm_endpoint raises ConfigError":
    var cfg = defaultConfig()
    cfg.vllmEndpoint = ""
    expect ConfigError:
      validate(cfg)

  test "empty openrouter_endpoint raises ConfigError":
    var cfg = defaultConfig()
    cfg.openrouterEndpoint = ""
    expect ConfigError:
      validate(cfg)

  test "empty db_path raises ConfigError":
    var cfg = defaultConfig()
    cfg.dbPath = ""
    expect ConfigError:
      validate(cfg)

# ---------------------------------------------------------------------------
# Suite: MCP server configuration — TOML
# ---------------------------------------------------------------------------

suite "mcpServers TOML loading":
  let tmpDir = getTempDir() / "talos_test_mcp_toml"
  setup: createDir(tmpDir)
  teardown: removeDir(tmpDir)

  test "loads single MCP server from TOML":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, """
[mcp_servers.fst]
url = "http://localhost:8080/mcp"
auth_token = "secret123"
timeout_ms = 5000
enabled = true
""")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.mcpServers.len == 1
    check cfg.mcpServers[0].url == "http://localhost:8080/mcp"
    check cfg.mcpServers[0].authToken == "secret123"
    check cfg.mcpServers[0].timeoutMs == 5000
    check cfg.mcpServers[0].enabled == true

  test "loads multiple MCP servers from TOML":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, """
[mcp_servers.fst]
url = "http://localhost:8080/mcp"

[mcp_servers.second]
url = "https://mcp.example.com/api"
enabled = false
""")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.mcpServers.len == 2
    check cfg.mcpServers[0].url == "http://localhost:8080/mcp"
    check cfg.mcpServers[0].enabled == true
    check cfg.mcpServers[1].url == "https://mcp.example.com/api"
    check cfg.mcpServers[1].enabled == false

  test "missing url field leaves server with default URL":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, """
[mcp_servers.test]
enabled = true
""")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.mcpServers.len == 1
    # Should use default URL, not crash
    check cfg.mcpServers[0].url == DefaultMcpServerUrl

  test "TOML url trailing slash is stripped":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, """
[mcp_servers.test]
url = "http://localhost:8080/mcp/"
""")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.mcpServers[0].url == "http://localhost:8080/mcp"

  test "invalid timeout_ms raises ConfigError":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, """
[mcp_servers.test]
url = "http://localhost:8080"
timeout_ms = "not-an-integer"
""")
    expect ConfigError:
      discard loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")

  test "enabled = false disables server":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, """
[mcp_servers.test]
url = "http://localhost:8080/mcp"
enabled = false
""")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.mcpServers.len == 1
    check cfg.mcpServers[0].enabled == false

  test "enabled = true enables server":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, """
[mcp_servers.test]
url = "http://localhost:8080/mcp"
enabled = true
""")
    let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
    check cfg.mcpServers[0].enabled == true

  test "mcpServers empty by default":
    let cfg = defaultConfig()
    check cfg.mcpServers.len == 0

  test "env var overrides TOML MCP server":
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, """
[mcp_servers.test]
url = "http://localhost:8080/mcp"
""")
    withEnv("MERCURY_MCP_SERVER_0_URL", "http://override:9000/mcp"):
      let cfg = loadConfig(configPath = cfgFile, envFilePath = "/nonexistent/.env")
      # env adds a new server after TOML ones
      check cfg.mcpServers.len == 2
      check cfg.mcpServers[1].url == "http://override:9000/mcp"

# ---------------------------------------------------------------------------
# Suite: MCP server configuration — env vars
# ---------------------------------------------------------------------------

suite "mcpServers env var loading":
  test "MERCURY_MCP_SERVER_0_URL creates server":
    withEnv("MERCURY_MCP_SERVER_0_URL", "http://env-server:8080/mcp"):
      let cfg = loadConfig(
        configPath = "/nonexistent/config.toml",
        envFilePath = "/nonexistent/.env"
      )
      check cfg.mcpServers.len == 1
      check cfg.mcpServers[0].url == "http://env-server:8080/mcp"
      check cfg.mcpServers[0].enabled == true

  test "MERCURY_MCP_SERVER_0_AUTH_TOKEN sets token":
    withEnv("MERCURY_MCP_SERVER_0_URL", "http://localhost:8080/mcp"):
      withEnv("MERCURY_MCP_SERVER_0_AUTH_TOKEN", "my-secret-token"):
        let cfg = loadConfig(
          configPath = "/nonexistent/config.toml",
          envFilePath = "/nonexistent/.env"
        )
        check cfg.mcpServers[0].authToken == "my-secret-token"

  test "MERCURY_MCP_SERVER_0_TIMEOUT_MS sets timeout":
    withEnv("MERCURY_MCP_SERVER_0_URL", "http://localhost:8080/mcp"):
      withEnv("MERCURY_MCP_SERVER_0_TIMEOUT_MS", "15000"):
        let cfg = loadConfig(
          configPath = "/nonexistent/config.toml",
          envFilePath = "/nonexistent/.env"
        )
        check cfg.mcpServers[0].timeoutMs == 15000

  test "MERCURY_MCP_SERVER_0_ENABLED=false disables":
    withEnv("MERCURY_MCP_SERVER_0_URL", "http://localhost:8080/mcp"):
      withEnv("MERCURY_MCP_SERVER_0_ENABLED", "false"):
        let cfg = loadConfig(
          configPath = "/nonexistent/config.toml",
          envFilePath = "/nonexistent/.env"
        )
        check cfg.mcpServers[0].enabled == false

  test "multiple env var servers":
    withEnv("MERCURY_MCP_SERVER_0_URL", "http://first:8080"):
      withEnv("MERCURY_MCP_SERVER_1_URL", "http://second:9000"):
        withEnv("MERCURY_MCP_SERVER_2_URL", "http://third:7000"):
          let cfg = loadConfig(
            configPath = "/nonexistent/config.toml",
            envFilePath = "/nonexistent/.env"
          )
          check cfg.mcpServers.len == 3
          check cfg.mcpServers[0].url == "http://first:8080"
          check cfg.mcpServers[1].url == "http://second:9000"
          check cfg.mcpServers[2].url == "http://third:7000"

  test "gap in index stops parsing":
    withEnv("MERCURY_MCP_SERVER_0_URL", "http://first:8080"):
      withEnv("MERCURY_MCP_SERVER_2_URL", "http://third:9000"):
        let cfg = loadConfig(
          configPath = "/nonexistent/config.toml",
          envFilePath = "/nonexistent/.env"
        )
        # Stops at gap — only server 0 is created, server 2 is never reached
        check cfg.mcpServers.len == 1
        check cfg.mcpServers[0].url == "http://first:8080"

  test "invalid timeout env var raises ConfigError":
    withEnv("MERCURY_MCP_SERVER_0_URL", "http://localhost:8080"):
      withEnv("MERCURY_MCP_SERVER_0_TIMEOUT_MS", "not-a-number"):
        expect ConfigError:
          discard loadConfig(
            configPath = "/nonexistent/config.toml",
            envFilePath = "/nonexistent/.env"
          )

  test "no env vars means no MCP servers":
    let cfg = loadConfig(
      configPath = "/nonexistent/config.toml",
      envFilePath = "/nonexistent/.env"
    )
    check cfg.mcpServers.len == 0
