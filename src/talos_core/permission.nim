import discord_types

type
  ToolRiskLevel* = enum
    riskNone
    riskLow
    riskMedium
    riskHigh
    riskCritical

  PermissionDecision* = enum
    pdAllow
    pdDeny
    pdAsk

proc getToolRisk*(toolName: string): ToolRiskLevel =
  case toolName
  of "shell", "bash", "execute": riskHigh
  of "file_write", "delete_file": riskMedium
  of "file_read", "read_file", "search": riskLow
  else: riskMedium

proc isAdmin*(userId: string, cfg: DiscordConfig): bool =
  if userId in cfg.admins.deny:
    return false
  return userId in cfg.admins.allow

proc isUserAllowed*(userId: string, cfg: DiscordConfig): bool =
  if userId in cfg.users.deny:
    return false
  if userId in cfg.users.allow:
    return true
  return isAdmin(userId, cfg)

proc canUseTool*(
    userId: string, toolName: string, cfg: DiscordConfig
): PermissionDecision =
  # check user in allow list
  if not isUserAllowed(userId, cfg):
    return pdDeny

  # check tool explicit deny
  if toolName in cfg.tools.deny:
    return pdDeny

  # check tool explicit allow
  if toolName in cfg.tools.allow:
    return pdAllow

  # check tool risk
  let risk = getToolRisk(toolName)

  if risk == riskNone or risk == riskLow:
    return pdAllow

  if risk == riskMedium:
    if isAdmin(userId, cfg):
      return pdAllow
    else:
      return pdAsk

  if risk == riskHigh or risk == riskCritical:
    return pdAsk

  return pdDeny
