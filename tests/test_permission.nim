import unittest
import talos_core/acl
import talos_core/permission

suite "Permission Framework":
  setup:
    var acl = ToolAcl()
    acl.admins.allow.add("admin_user")
    acl.users.allow.add("normal_user")
    acl.users.deny.add("banned_user")
    acl.tools.deny.add("banned_tool")
    acl.tools.allow.add("safe_tool")

  # ---------------------------------------------------------------------------
  # isAdmin
  # ---------------------------------------------------------------------------

  test "isAdmin - explicit allow":
    check isAdmin("admin_user", acl) == true

  test "isAdmin - normal user is not admin":
    check isAdmin("normal_user", acl) == false

  test "isAdmin - unknown user is not admin":
    check isAdmin("unknown_user", acl) == false

  test "isAdmin - admin in deny list is not admin":
    acl.admins.deny.add("admin_user")
    check isAdmin("admin_user", acl) == false

  # ---------------------------------------------------------------------------
  # isUserAllowed
  # ---------------------------------------------------------------------------

  test "isUserAllowed - admin is allowed":
    check isUserAllowed("admin_user", acl) == true

  test "isUserAllowed - normal user is allowed":
    check isUserAllowed("normal_user", acl) == true

  test "isUserAllowed - banned user is denied":
    check isUserAllowed("banned_user", acl) == false

  test "isUserAllowed - unknown user is denied":
    check isUserAllowed("unknown_user", acl) == false

  test "isUserAllowed - empty config denies everyone":
    var emptyAcl = ToolAcl()
    check isUserAllowed("anyone", emptyAcl) == false
    check isUserAllowed("admin", emptyAcl) == false

  test "isUserAllowed - user in both allow and deny is denied":
    acl.users.allow.add("both_user")
    acl.users.deny.add("both_user")
    check isUserAllowed("both_user", acl) == false

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
    check canUseTool("unknown_user", "read_file", acl) == pdDeny
    check canUseTool("unknown_user", "shell", acl) == pdDeny

  test "canUseTool - banned user is denied":
    check canUseTool("banned_user", "read_file", acl) == pdDeny
    check canUseTool("banned_user", "safe_tool", acl) == pdDeny

  # ---------------------------------------------------------------------------
  # canUseTool — explicit deny overrides everything
  # ---------------------------------------------------------------------------

  test "canUseTool - explicit deny blocks admin":
    check canUseTool("admin_user", "banned_tool", acl) == pdDeny

  test "canUseTool - explicit deny on low-risk tool":
    acl.tools.deny.add("read_file")
    check canUseTool("admin_user", "read_file", acl) == pdDeny

  test "canUseTool - explicit deny on explicitly allowed tool":
    acl.tools.deny.add("safe_tool")
    check canUseTool("normal_user", "safe_tool", acl) == pdDeny

  # ---------------------------------------------------------------------------
  # canUseTool — explicit allow
  # ---------------------------------------------------------------------------

  test "canUseTool - explicit allow for normal user":
    check canUseTool("normal_user", "safe_tool", acl) == pdAllow

  test "canUseTool - explicit allow for high-risk tool":
    acl.tools.allow.add("shell")
    check canUseTool("normal_user", "shell", acl) == pdAllow
    check canUseTool("admin_user", "shell", acl) == pdAllow

  test "canUseTool - explicit allow for banned user overrides user deny":
    acl.tools.allow.add("read_file")
    check canUseTool("banned_user", "read_file", acl) == pdDeny

  # ---------------------------------------------------------------------------
  # canUseTool — risk low/none
  # ---------------------------------------------------------------------------

  test "canUseTool - riskLow allows all users":
    check canUseTool("normal_user", "read_file", acl) == pdAllow
    check canUseTool("admin_user", "read_file", acl) == pdAllow

  test "canUseTool - riskLow for admin":
    check canUseTool("admin_user", "search", acl) == pdAllow

  # ---------------------------------------------------------------------------
  # canUseTool — risk medium
  # ---------------------------------------------------------------------------

  test "canUseTool - riskMedium normal user gets ask":
    check canUseTool("normal_user", "file_write", acl) == pdAsk

  test "canUseTool - riskMedium admin bypasses ask":
    check canUseTool("admin_user", "file_write", acl) == pdAllow

  test "canUseTool - riskMedium unknown default tool":
    check canUseTool("normal_user", "weird_tool", acl) == pdAsk
    check canUseTool("admin_user", "weird_tool", acl) == pdAllow

  # ---------------------------------------------------------------------------
  # canUseTool — risk high / critical
  # ---------------------------------------------------------------------------

  test "canUseTool - riskHigh normal user gets ask":
    check canUseTool("normal_user", "shell", acl) == pdAsk

  test "canUseTool - riskHigh admin is allowed":
    # Admin fast-path: without it, gating shell through canUseTool would
    # return pdAsk for every caller — disabling the tool outright in
    # daemon mode, where no interactive approval flow exists.
    check canUseTool("admin_user", "shell", acl) == pdAllow

  # ---------------------------------------------------------------------------
  # canUseTool — edge cases
  # ---------------------------------------------------------------------------

  test "canUseTool - empty config returns pdDeny for all":
    var emptyAcl = ToolAcl()
    check canUseTool("anyone", "read_file", emptyAcl) == pdDeny
    check canUseTool("anyone", "shell", emptyAcl) == pdDeny

  test "canUseTool - admin with no users config still allowed":
    var adminOnlyAcl = ToolAcl()
    adminOnlyAcl.admins.allow.add("superadmin")
    check canUseTool("superadmin", "read_file", adminOnlyAcl) == pdAllow
    check canUseTool("superadmin", "file_write", adminOnlyAcl) == pdAllow

  test "canUseTool - multiple tool denies work independently":
    acl.tools.deny.add("read_file")
    acl.tools.deny.add("shell")
    check canUseTool("admin_user", "read_file", acl) == pdDeny
    check canUseTool("admin_user", "shell", acl) == pdDeny
    check canUseTool("admin_user", "file_write", acl) == pdAllow

  test "canUseTool - allow list does not affect unrelated tools":
    check canUseTool("normal_user", "write_file", acl) == pdAsk
    check canUseTool("normal_user", "safe_tool", acl) == pdAllow

  test "canUseTool - deny list does not affect unrelated tools":
    check canUseTool("admin_user", "file_write", acl) == pdAllow
    check canUseTool("admin_user", "banned_tool", acl) == pdDeny
