## Shared utility helpers used across talos_core modules.
##
## Centralizes small helpers that were previously copy-pasted into
## individual modules (timestamps, session IDs, HTTP status parsing).

import std/[strutils, times]

proc nowIso*(): string =
  ## Returns the current UTC time as an ISO 8601 string.
  let t = now().utc
  return t.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc generateSessionId*(salt: int = 0): string =
  ## Generates a session ID based on the current UTC timestamp plus a
  ## nanosecond component for uniqueness. `salt`, when non-zero, adds a
  ## disambiguating suffix for retrying after a collision.
  let t = now().utc
  result = "sess_" & t.format("yyyyMMdd'T'HHmmss") & "_" & $getTime().nanosecond
  if salt > 0:
    result.add("_" & $salt)

proc parseStatusCode*(status: string): int =
  ## Parses the integer code from an HTTP status line like "200 OK".
  let s = status.strip()
  let spaceIdx = s.find(' ')
  let codePart = if spaceIdx >= 0: s[0 ..< spaceIdx] else: s
  try:
    return parseInt(codePart)
  except ValueError:
    return 0
