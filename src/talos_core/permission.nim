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

  if risk == riskLow:
    return pdAllow

  if risk == riskMedium:
    if isAdmin(userId, cfg):
      return pdAllow
    else:
      return pdAsk

  if risk == riskHigh:
    # Same shape as riskMedium but stricter for non-admins: admins get the
    # tool, everyone else needs approval. Without an admin fast-path here,
    # gating shell through canUseTool would return pdAsk for every caller
    # in daemon mode — i.e. disable the tool outright, since there is no
    # interactive approval flow. Operators who want shell for non-admin
    # users can still add it to tools.allow explicitly.
    if isAdmin(userId, cfg):
      return pdAllow
    else:
      return pdAsk

  if risk == riskCritical:
    return pdAsk

  return pdDeny
