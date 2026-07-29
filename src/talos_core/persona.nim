import std/[os, tables, streams, strutils, parsecfg, sequtils, sets]
import talos_core/config
import talos_core/tool_registry

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  MemoryScope* = enum
    msOwnSessions
    msNone
    msShared

  PersonaConfig* = object
    name*: string
    systemPrompt*: string
    model*: string
    modelRole*: string
      ## Named role (task-13, build_llm_client.resolveRole) to route this
      ## persona's child-agent LLM calls through, e.g. "smol" for cheap
      ## subagent fan-out. "" (the default) means "default" role — i.e.
      ## reuse the parent's own LLM client unchanged.
    temperature*: float
    maxIterations*: int
    toolsAllow*: seq[string]
    toolsDeny*: seq[string]
    memoryScope*: MemoryScope
    memoryMaxHistory*: int
    memoryFtsEnabled*: bool
    delegateEnabled*: bool
    maxDelegationDepth*: int
    maxDelegationsPerRun*: int
    specialty*: string
      ## Comma-separated keywords/phrases describing what this persona is
      ## suited for (e.g. "code review, testing, quality"), consulted by
      ## `routeToDelegate` (task-17) when a `delegate` call doesn't name a
      ## persona explicitly. "" means this persona is never auto-routed to
      ## — it can still be delegated to by explicit name.

  PersonaRegistry* = ref object
    personas*: OrderedTable[string, PersonaConfig]

  PersonaError* = object of CatchableError

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

const
  DefaultMemoryScope* = msOwnSessions
  DefaultMemoryMaxHistory* = 0
  DefaultMemoryFtsEnabled* = false
  DefaultDelegateEnabled* = true
  DefaultMaxDelegationDepth* = 2
  DefaultMaxDelegationsPerRun* = 5

# ---------------------------------------------------------------------------
# Registry construction
# ---------------------------------------------------------------------------

proc newPersonaRegistry*(): PersonaRegistry =
  PersonaRegistry(personas: initOrderedTable[string, PersonaConfig]())

# ---------------------------------------------------------------------------
# Persona loading from TOML
# ---------------------------------------------------------------------------

proc applyPersonaDefaults(pc: var PersonaConfig) =
  ## Fills zero-value fields with safe defaults. Call before spawning.
  ##
  ## NOTE: `delegateEnabled` is deliberately not defaulted here. A plain
  ## `bool` can't distinguish "TOML never set delegate_enabled" from
  ## "TOML explicitly set delegate_enabled = false" — both read as Nim's
  ## zero value. Defaulting it to `DefaultDelegateEnabled` (true) from
  ## this point on would silently re-enable delegation for personas that
  ## explicitly opted out. Instead, `loadPersonasFromStream` seeds each
  ## persona buffer with `DefaultDelegateEnabled` before parsing, so an
  ## explicit `delegate_enabled = false` in the file is the only way to
  ## end up with `false` here.
  if pc.memoryMaxHistory <= 0:
    pc.memoryMaxHistory = DefaultMemoryMaxHistory
  if pc.maxDelegationDepth <= 0:
    pc.maxDelegationDepth = DefaultMaxDelegationDepth
  if pc.maxDelegationsPerRun <= 0:
    pc.maxDelegationsPerRun = DefaultMaxDelegationsPerRun
  if pc.maxIterations <= 0:
    pc.maxIterations = DefaultMaxLoopIterations

proc registerPersona*(reg: var PersonaRegistry; pc: PersonaConfig) =
  ## Registers a persona. Raises PersonaError on duplicate name.
  let name = pc.name.toLowerAscii()
  if name.len == 0:
    raise newException(PersonaError, "persona name must be non-empty")
  if reg.personas.hasKey(name):
    raise newException(PersonaError,
      "persona '" & name & "' is already registered")
  var p = pc
  p.name = name
  applyPersonaDefaults(p)
  reg.personas[name] = p

proc parseMemoryScope(val: string): MemoryScope =
  case val.toLowerAscii()
  of "own_sessions", "own":    result = msOwnSessions
  of "none", "stateless":      result = msNone
  of "shared":                 result = msShared
  else:
    result = msOwnSessions

proc parseBool(val: string): bool =
  val.toLowerAscii() in @["1", "true", "yes", "on", "enabled"]

proc loadPersonasFromStream*(reg: var PersonaRegistry; stream: Stream) =
  ## Loads persona entries from a TOML/INI-style stream.
  ## Skips unknown sections and keys silently.
  var currentSection = ""
  var buf = PersonaConfig()

  var parser: CfgParser
  open(parser, stream, "personas")
  defer: close(parser)

  while true:
    let event = next(parser)
    case event.kind
    of cfgEof:
      # Flush last persona if any
      if currentSection.startsWith("personas.") and buf.name.len > 0:
        registerPersona(reg, buf)
      break
    of cfgSectionStart:
      # New section — flush previous
      if currentSection.startsWith("personas.") and buf.name.len > 0:
        registerPersona(reg, buf)
      currentSection = event.section
      if currentSection.startsWith("personas."):
        # Seed with the documented default; an explicit `delegate_enabled`
        # key below (if present) is the only thing that can override it.
        buf = PersonaConfig(
          name: currentSection.split('.')[1],
          delegateEnabled: DefaultDelegateEnabled,
        )
      else:
        buf = PersonaConfig()
    of cfgKeyValuePair:
      if not currentSection.startsWith("personas."):
        continue
      let k = event.key.toLowerAscii()
      case k
      of "system_prompt", "prompt":
        buf.systemPrompt = event.value
      of "model":
        buf.model = event.value
      of "model_role":
        buf.modelRole = event.value
      of "temperature":
        try:
          buf.temperature = parseFloat(event.value)
        except ValueError:
          discard
      of "max_iterations":
        try:
          buf.maxIterations = parseInt(event.value)
        except ValueError:
          discard
      of "tools_allow":
        buf.toolsAllow = event.value.split(',')
          .mapIt(it.strip()).filterIt(it.len > 0)
      of "tools_deny":
        buf.toolsDeny = event.value.split(',')
          .mapIt(it.strip()).filterIt(it.len > 0)
      of "memory_scope":
        buf.memoryScope = parseMemoryScope(event.value)
      of "memory_max_history":
        try:
          buf.memoryMaxHistory = parseInt(event.value)
        except ValueError:
          discard
      of "memory_fts_enabled":
        buf.memoryFtsEnabled = parseBool(event.value)
      of "delegate_enabled":
        buf.delegateEnabled = parseBool(event.value)
      of "max_delegation_depth":
        try:
          buf.maxDelegationDepth = parseInt(event.value)
        except ValueError:
          discard
      of "max_delegations_per_run":
        try:
          buf.maxDelegationsPerRun = parseInt(event.value)
        except ValueError:
          discard
      of "specialty":
        buf.specialty = event.value
      else:
        discard
    of cfgOption:
      discard
    of cfgError:
      # A genuine syntax error (e.g. a missing `=`). Discarding it means
      # the affected key silently never applies — same bug class as the
      # .env parser's silently-discarded parse failures, which config.nim
      # already fixed by raising ConfigError.
      raise newException(PersonaError,
        "personas file syntax error: " & event.msg)

proc loadPersonasFile*(path: string): PersonaRegistry =
  ## Loads all personas from a TOML/INI config file.
  result = newPersonaRegistry()
  if not fileExists(path):
    return
  var stream = newFileStream(path, fmRead)
  if stream == nil:
    raise newException(PersonaError,
      "cannot open personas file: " & path)
  defer: stream.close()
  loadPersonasFromStream(result, stream)

# ---------------------------------------------------------------------------
# Lookup
# ---------------------------------------------------------------------------

proc getPersona*(reg: PersonaRegistry; name: string): PersonaConfig =
  ## Returns the named persona. Raises PersonaError if not found.
  let key = name.toLowerAscii()
  if not reg.personas.hasKey(key):
    raise newException(PersonaError,
      "persona '" & name & "' not found. Available: " &
      reg.personas.keys.toSeq().join(", "))
  result = reg.personas[key]

proc hasPersona*(reg: PersonaRegistry; name: string): bool =
  reg.personas.hasKey(name.toLowerAscii())

proc listPersonas*(reg: PersonaRegistry): seq[string] =
  result = @[]
  for name in reg.personas.keys:
    result.add(name)

# ---------------------------------------------------------------------------
# Tool registry filtering
# ---------------------------------------------------------------------------

proc filterToolsByPersona*(
    persona: PersonaConfig;
    allTools: seq[string];
): seq[string] =
  ## Filters `allTools` according to the persona's toolsAllow and toolsDeny
  ## lists. Returns the subset of tools the persona is allowed to use.
  ##
  ## Logic:
  ##   - if toolsAllow is non-empty: keep only named tools (minus deny)
  ##   - if toolsAllow is empty and toolsDeny is non-empty: remove denied tools
  ##   - if both empty: all tools pass
  result = @[]
  let allowSet = if persona.toolsAllow.len > 0:
    persona.toolsAllow.toHashSet()
  else:
    initHashSet[string]()
  let denySet = persona.toolsDeny.toHashSet()

  for toolName in allTools:
    if denySet.contains(toolName):
      continue
    if allowSet.len > 0 and not allowSet.contains(toolName):
      continue
    result.add(toolName)

proc scopedRegistry*(
    base: ToolRegistry;
    persona: PersonaConfig;
): ToolRegistry =
  ## Produces a new ToolRegistry filtered according to the persona's
  ## toolsAllow and toolsDeny lists.
  ##
  ## Logic:
  ##   - if toolsAllow is non-empty: keep only named tools + add any deny removals
  ##   - if toolsAllow is empty and toolsDeny is non-empty: remove denied tools
  ##   - if both empty: clone all tools from base
  result = newToolRegistry()
  let allowSet = if persona.toolsAllow.len > 0:
    persona.toolsAllow.toHashSet()
  else:
    initHashSet[string]()
  let denySet = persona.toolsDeny.toHashSet()
  let allowNonEmpty = persona.toolsAllow.len > 0

  for tool in base.list():
    let name = tool.name
    if denySet.contains(name):
      continue
    if allowNonEmpty and not allowSet.contains(name):
      continue
    result.register(tool)

# ---------------------------------------------------------------------------
# Subagent dispatch routing (task-17)
# ---------------------------------------------------------------------------

const DefaultRoutingPersonaName* = "default"
  ## A persona registered under this name is the routing fallback consulted
  ## by `routeToDelegate` when no persona's `specialty` matches the task
  ## description — i.e. "configuring a default persona" (per task-17's
  ## acceptance criteria) means simply registering a persona named
  ## "default" in personas.toml, no separate config surface needed.

proc specialtyKeywords(persona: PersonaConfig): seq[string] =
  persona.specialty.split(',').mapIt(it.strip().toLowerAscii()).filterIt(it.len > 0)

proc routeToDelegate*(
    reg: PersonaRegistry;
    taskDescription: string;
    explicitPersona: string = "";
    defaultPersona: string = DefaultRoutingPersonaName;
): string =
  ## Picks which persona a `delegate` call should route to.
  ##
  ## `explicitPersona`, if non-empty, always wins outright — the router
  ## never overrides a caller's manual choice, and doesn't even inspect
  ## `taskDescription` in that case.
  ##
  ## Otherwise, each registered persona's `specialty` (comma-separated
  ## keywords/phrases) is matched as a case-insensitive substring against
  ## `taskDescription`; the persona with the most matching keywords wins,
  ## ties going to whichever matching persona was registered first. This
  ## is a deliberately simple rules-based classifier rather than a cheap
  ## LLM call (task-13's "smol" role would be the natural home for that
  ## upgrade later) — deterministic and instant, no network dependency for
  ## a decision this cheap to get right most of the time.
  ##
  ## If no persona's specialty matches at all, falls back to
  ## `defaultPersona` (default: a persona literally named "default", if
  ## one is registered). Raises PersonaError if there's no match and no
  ## usable default — silently guessing wrong on a delegate call is worse
  ## than failing loudly, since the entire point of routing is picking the
  ## *right* child agent for the subtask.
  if explicitPersona.len > 0:
    return explicitPersona.toLowerAscii()

  let taskLower = taskDescription.toLowerAscii()
  var bestName = ""
  var bestScore = 0
  for name, pc in reg.personas:
    var score = 0
    for kw in specialtyKeywords(pc):
      if taskLower.contains(kw):
        inc score
    if score > bestScore:
      bestScore = score
      bestName = name

  if bestName.len > 0:
    return bestName

  if defaultPersona.len > 0 and reg.hasPersona(defaultPersona):
    return defaultPersona.toLowerAscii()

  raise newException(PersonaError,
    "routeToDelegate: no persona's specialty matched the task description" &
    ", and no usable default persona (\"" & defaultPersona & "\") is registered")