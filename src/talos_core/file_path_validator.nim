import os, strutils, uri
import std/re

type
  PathDecision* = enum
    pathAllow
    pathAsk
    pathDeny
    pathInvalid

  ValidationResult* = object
    decision*: PathDecision
    resolvedPath*: string
    reason*: string

  FileRules* = object
    sandboxDir*: string
    allowPatterns*: seq[string]
    askPatterns*: seq[string]
    denyPatterns*: seq[string]

const mandatoryDenyPatterns = @[
  ".env", ".env.*", "*.key", "*.pem", "*/.ssh/*", ".ssh/*", "*/.aws/*", ".aws/*", "*/.gnupg/*", ".gnupg/*"
]

proc resolvePathSafe*(path: string): string =
  var current = path
  var unexisting: seq[string] = @[]
  
  while current != "" and current != "/" and current != "." and not fileExists(current) and not dirExists(current):
    let parts = splitPath(current)
    if parts.tail != "":
      unexisting.insert(parts.tail, 0)
    current = parts.head
    if parts.head == current and parts.tail == "": break

  if current == "" or current == ".":
    current = getCurrentDir()
  
  if current != "/" and current != "":
    try:
      current = expandFilename(current)
    except OSError:
      discard # Keep current as is if expansion fails

  for part in unexisting:
    current = current / part
    
  return normalizedPath(current)

proc matchPattern(path: string, pattern: string): bool =
  # Simple glob matching
  try:
    # Convert glob to regex
    var rePattern = pattern.replace(".", "\\.").replace("*", ".*").replace("?", ".")
    rePattern = "^" & rePattern & "$"
    let r = re(rePattern)
    return path.match(r)
  except RegexError:
    return false

proc matchAnyPattern(path: string, patterns: seq[string]): bool =
  let filename = extractFilename(path)
  # Check both full path and filename against patterns
  for p in patterns:
    if matchPattern(path, p) or matchPattern(filename, p):
      return true
    # Also check if it's a directory match like .ssh/*
    if p.endsWith("/*"):
      let prefix = p[0..^3]
      if path.contains("/" & prefix & "/") or path.contains("\\" & prefix & "\\"):
        return true
      if path.startsWith(prefix & "/") or path.startsWith(prefix & "\\"):
        return true
  return false

proc validatePath*(path: string, rules: FileRules): ValidationResult =
  var p = path
  
  # 1. URL decoding
  if p.contains("%"):
    try:
      p = decodeUrl(p)
    except ValueError:
      return ValidationResult(decision: pathInvalid, resolvedPath: p,
                              reason: "Malformed percent-encoding in path")
    
  # 2. Tilde expansion
  if p.startsWith("~"):
    p = expandTilde(p)
    
  # 3. Resolve symlinks safely (even if file doesn't exist)
  p = resolvePathSafe(p)
  
  # 4. Sandbox check
  #    Require an exact match or a real directory boundary ("/") after the
  #    sandbox prefix. A bare startsWith would let a sibling directory that
  #    merely shares the prefix (e.g. /home/u/sandbox-evil for a
  #    /home/u/sandbox sandbox) escape the sandbox.
  if rules.sandboxDir != "":
    let sandbox = resolvePathSafe(rules.sandboxDir)
    if p != sandbox and not p.startsWith(sandbox & "/"):
      return ValidationResult(decision: pathDeny, resolvedPath: p, reason: "Path escapes sandbox")
      
  # 5. Mandatory deny list
  if matchAnyPattern(p, mandatoryDenyPatterns):
    return ValidationResult(decision: pathDeny, resolvedPath: p, reason: "Matches mandatory deny pattern")
    
  # 6. User deny list
  if matchAnyPattern(p, rules.denyPatterns):
    return ValidationResult(decision: pathDeny, resolvedPath: p, reason: "Matches deny pattern")
    
  # 7. Ask list
  if matchAnyPattern(p, rules.askPatterns):
    return ValidationResult(decision: pathAsk, resolvedPath: p, reason: "Matches ask pattern")
    
  # 8. Allow list
  if matchAnyPattern(p, rules.allowPatterns):
    return ValidationResult(decision: pathAllow, resolvedPath: p, reason: "Matches allow pattern")
    
  # Default to deny if no match
  return ValidationResult(decision: pathDeny, resolvedPath: p, reason: "Path not in allow list")

