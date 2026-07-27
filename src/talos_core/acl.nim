## Generic caller-identity access control.
##
## Product-agnostic: no notion of Discord, channels, or tokens — just
## "who can do what." Products (the Discord daemon, a future email/CLI
## surface, etc.) adapt their own config into a `ToolAcl` at their own
## boundary; core only ever sees this shape.

type
  AccessControl* = object
    allow*: seq[string]
    deny*: seq[string]

  ToolAcl* = object
    admins*: AccessControl
    users*: AccessControl
    tools*: AccessControl
