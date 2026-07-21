import unittest
import talos_core/discord_types
import talos_core/permission

suite "Permission Framework":
  setup:
    var cfg = defaultDiscordConfig()
    cfg.admins.allow.add("admin_user")
    cfg.users.allow.add("normal_user")
    cfg.users.deny.add("banned_user")
    cfg.tools.deny.add("banned_tool")
    cfg.tools.allow.add("safe_tool")

  # ---------------------------------------------------------------------------
  # isAdmin
  # ---------------------------------------------------------------------------

  test "isAdmin - explicit allow":
    check isAdmin("admin_user", cfg) == true

  test "isAdmin - normal user is not admin":
    check isAdmin("normal_user", cfg) == false

  test "isAdmin - unknown user is not admin":
    check isAdmin("unknown_user", cfg) == false

  test "isAdmin - admin in deny list is not admin":
    cfg.admins.deny.add("admin_user")
    check isAdmin("admin_user", cfg) == false

  # ---------------------------------------------------------------------------
  # isUserAllowed
  # ---------------------------------------------------------------------------

  test "isUserAllowed - admin is allowed":
    check isUserAllowed("admin_user", cfg) == true

  test "isUserAllowed - normal user is allowed":
    check isUserAllowed("normal_user", cfg) == true

  test "isUserAllowed - banned user is denied":
    check isUserAllowed("banned_user", cfg) == false

  test "isUserAllowed - unknown user is denied":
    check isUserAllowed("unknown_user", cfg) == false

  test "isUserAllowed - empty config denies everyone":
    var emptyCfg = defaultDiscordConfig()
    check isUserAllowed("anyone", emptyCfg) == false
    check isUserAllowed("admin", emptyCfg) == false

  test "isUserAllowed - user in both allow and deny is denied":
    cfg.users.allow.add("both_user")
    cfg.users.deny.add("both_user")
    check isUserAllowed("both_user", cfg) == false

  # ---------------------------------------------------------------------------
  # getToolRisk
  # ---------------------------------------------------------------------------

  test "getToolRisk - shell tools are riskHigh":
    check getToolRisk("shell") == riskHigh
    check getToolRisk("bash") == riskHigh
    check getToolRisk("execute") == riskHigh

  test "getToolRisk - file write is riskMedium":
    check getToolRisk("file_write") == riskMedium
    check getToolRisk("delete_file") == riskMedium

  test "getToolRisk - file read is riskLow":
    check getToolRisk("file_read") == riskLow
    check getToolRisk("read_file") == riskLow
    check getToolRisk("search") == riskLow

  test "getToolRisk - unknown tool defaults to riskMedium":
    check getToolRisk("unknown_tool") == riskMedium
    check getToolRisk("custom_plugin") == riskMedium

  # ---------------------------------------------------------------------------
  # canUseTool — user not allowed
  # ---------------------------------------------------------------------------

  test "canUseTool - unknown user is denied regardless of tool":
    check canUseTool("unknown_user", "read_file", cfg) == pdDeny
    check canUseTool("unknown_user", "shell", cfg) == pdDeny

  test "canUseTool - banned user is denied":
    check canUseTool("banned_user", "read_file", cfg) == pdDeny
    check canUseTool("banned_user", "safe_tool", cfg) == pdDeny

  # ---------------------------------------------------------------------------
  # canUseTool — explicit deny overrides everything
  # ---------------------------------------------------------------------------

  test "canUseTool - explicit deny blocks admin":
    check canUseTool("admin_user", "banned_tool", cfg) == pdDeny

  test "canUseTool - explicit deny on low-risk tool":
    cfg.tools.deny.add("read_file")
    check canUseTool("admin_user", "read_file", cfg) == pdDeny

  test "canUseTool - explicit deny on explicitly allowed tool":
    cfg.tools.deny.add("safe_tool")
    check canUseTool("normal_user", "safe_tool", cfg) == pdDeny

  # ---------------------------------------------------------------------------
  # canUseTool — explicit allow
  # ---------------------------------------------------------------------------

  test "canUseTool - explicit allow for normal user":
    check canUseTool("normal_user", "safe_tool", cfg) == pdAllow

  test "canUseTool - explicit allow for high-risk tool":
    cfg.tools.allow.add("shell")
    check canUseTool("normal_user", "shell", cfg) == pdAllow
    check canUseTool("admin_user", "shell", cfg) == pdAllow

  test "canUseTool - explicit allow for banned user overrides user deny":
    cfg.tools.allow.add("read_file")
    check canUseTool("banned_user", "read_file", cfg) == pdDeny

  # ---------------------------------------------------------------------------
  # canUseTool — risk low/none
  # ---------------------------------------------------------------------------

  test "canUseTool - riskLow allows all users":
    check canUseTool("normal_user", "read_file", cfg) == pdAllow
    check canUseTool("admin_user", "read_file", cfg) == pdAllow

  test "canUseTool - riskLow for admin":
    check canUseTool("admin_user", "search", cfg) == pdAllow

  # ---------------------------------------------------------------------------
  # canUseTool — risk medium
  # ---------------------------------------------------------------------------

  test "canUseTool - riskMedium normal user gets ask":
    check canUseTool("normal_user", "file_write", cfg) == pdAsk

  test "canUseTool - riskMedium admin bypasses ask":
    check canUseTool("admin_user", "file_write", cfg) == pdAllow

  test "canUseTool - riskMedium unknown default tool":
    check canUseTool("normal_user", "weird_tool", cfg) == pdAsk
    check canUseTool("admin_user", "weird_tool", cfg) == pdAllow

  # ---------------------------------------------------------------------------
  # canUseTool — risk high / critical
  # ---------------------------------------------------------------------------

  test "canUseTool - riskHigh normal user gets ask":
    check canUseTool("normal_user", "shell", cfg) == pdAsk

  test "canUseTool - riskHigh admin also gets ask":
    check canUseTool("admin_user", "shell", cfg) == pdAsk

  # ---------------------------------------------------------------------------
  # canUseTool — edge cases
  # ---------------------------------------------------------------------------

  test "canUseTool - empty config returns pdDeny for all":
    var emptyCfg = defaultDiscordConfig()
    check canUseTool("anyone", "read_file", emptyCfg) == pdDeny
    check canUseTool("anyone", "shell", emptyCfg) == pdDeny

  test "canUseTool - admin with no users config still allowed":
    var adminOnlyCfg = defaultDiscordConfig()
    adminOnlyCfg.admins.allow.add("superadmin")
    check canUseTool("superadmin", "read_file", adminOnlyCfg) == pdAllow
    check canUseTool("superadmin", "file_write", adminOnlyCfg) == pdAllow

  test "canUseTool - multiple tool denies work independently":
    cfg.tools.deny.add("read_file")
    cfg.tools.deny.add("shell")
    check canUseTool("admin_user", "read_file", cfg) == pdDeny
    check canUseTool("admin_user", "shell", cfg) == pdDeny
    check canUseTool("admin_user", "file_write", cfg) == pdAllow

  test "canUseTool - allow list does not affect unrelated tools":
    check canUseTool("normal_user", "write_file", cfg) == pdAsk
    check canUseTool("normal_user", "safe_tool", cfg) == pdAllow

  test "canUseTool - deny list does not affect unrelated tools":
    check canUseTool("admin_user", "file_write", cfg) == pdAllow
    check canUseTool("admin_user", "banned_tool", cfg) == pdDeny
