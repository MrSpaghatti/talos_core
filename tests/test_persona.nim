import std/[unittest, streams, json]
import talos_core/[persona, delegate, tool_registry]

proc dummyTool(name: string): Tool =
  ## A trivial no-op tool used to exercise registry-scoping plumbing.
  newTool(
    name = name,
    description = "test tool",
    parameters = %*{"type": "object", "properties": {}},
    execute = proc (args: JsonNode): ToolResult {.gcsafe, raises: [].} =
      ToolResult(output: "", isError: false, exitCode: 0)
  )

suite "PersonaRegistry":

  test "empty allow list means all tools pass":
    let pc = PersonaConfig(
      name: "locked",
      systemPrompt: "All tools allowed by default.",
      toolsAllow: @[],
      toolsDeny: @[],
    )
    let filtered = filterToolsByPersona(pc, @["shell", "file_read", "file_write"])
    check: filtered.len == 3

  test "specific allow list filters correctly":
    let pc = PersonaConfig(
      name: "analyst",
      systemPrompt: "Read only.",
      toolsAllow: @["file_read"],
    )
    let filtered = filterToolsByPersona(pc, @["shell", "file_read", "file_write"])
    check: filtered.len == 1
    check: "file_read" in filtered
    check: "shell" notin filtered

  test "deny list removes specific tools":
    let pc = PersonaConfig(
      name: "cautious",
      systemPrompt: "No shell.",
      toolsAllow: @["shell", "file_read", "file_write"],
      toolsDeny: @["shell"],
    )
    let filtered = filterToolsByPersona(pc, @["shell", "file_read", "file_write"])
    check: filtered.len == 2
    check: "shell" notin filtered
    check: "file_read" in filtered

  test "unknown tool names in allow are ignored":
    let pc = PersonaConfig(
      name: "cautious",
      systemPrompt: "Only known tools.",
      toolsAllow: @["shell", "nonexistent_tool"],
    )
    let filtered = filterToolsByPersona(pc, @["shell", "file_read"])
    check: filtered.len == 1
    check: "shell" in filtered
    check: "nonexistent_tool" notin filtered

  test "scopedRegistry produces a real ToolRegistry containing only the allowed tools":
    ## Exercises `scopedRegistry` itself (used in production by the delegate
    ## and persona-task spawn paths in talos_agent.nim), not just the
    ## `filterToolsByPersona` name-list helper it's built on.
    var base = newToolRegistry()
    base.register(dummyTool("shell"))
    base.register(dummyTool("file_read"))
    base.register(dummyTool("file_write"))

    let pc = PersonaConfig(
      name: "writer",
      systemPrompt: "Write docs.",
      toolsAllow: @["file_read", "file_write"],
      toolsDeny: @[],
    )
    let scoped = scopedRegistry(base, pc)

    check: scoped.has("file_read")
    check: scoped.has("file_write")
    check: not scoped.has("shell")
    check: scoped.list().len == 2
    # The base registry must be untouched — scoping produces a new registry.
    check: base.has("shell")

  test "scopedRegistry applies deny even over an explicit allow entry":
    var base = newToolRegistry()
    base.register(dummyTool("shell"))
    base.register(dummyTool("file_read"))

    let pc = PersonaConfig(
      name: "conflicted",
      toolsAllow: @["shell", "file_read"],
      toolsDeny: @["shell"],
    )
    let scoped = scopedRegistry(base, pc)

    check: not scoped.has("shell")
    check: scoped.has("file_read")


suite "Memory scope":

  test "persona default memory scope is own_sessions":
    let pc = PersonaConfig(name: "default_persona")
    check: pc.memoryScope == msOwnSessions

  test "stateless persona has msNone":
    let pc = PersonaConfig(
      name: "stateless",
      memoryScope: msNone,
    )
    check: pc.memoryScope == msNone


suite "DelegationConfig":

  test "defaultDelegationConfig uses constants":
    let dc = defaultDelegationConfig()
    check: dc.maxDepth == delegate.DefaultMaxDelegationDepth
    check: dc.maxDelegations == delegate.DefaultMaxDelegationsPerRun

  test "canDelegate returns true when both > 0":
    var dc = defaultDelegationConfig()
    check: dc.canDelegate == true

  test "canDelegate returns false when depth is exhausted":
    var dc = defaultDelegationConfig()
    dc.maxDepth = 0
    check: dc.canDelegate == false

  test "canDelegate returns false when per-run count is exhausted":
    var dc = defaultDelegationConfig()
    dc.maxDelegations = 0
    check: dc.canDelegate == false

  test "useDelegationSlot decrements both counters":
    var dc = defaultDelegationConfig()
    let origDepth = dc.maxDepth
    let origDel = dc.maxDelegations
    dc.useDelegationSlot()
    check: dc.maxDepth == origDepth - 1
    check: dc.maxDelegations == origDel - 1

  test "applyPersonaDelegation uses defaults for empty ints":
    let dc = applyPersonaDelegation(0, 0, "test")
    check: dc.maxDepth == delegate.DefaultMaxDelegationDepth
    check: dc.maxDelegations == delegate.DefaultMaxDelegationsPerRun
    check: dc.personaName == "test"

  test "applyPersonaDelegation parses explicit values":
    let dc = applyPersonaDelegation(3, 10, "explicit")
    check: dc.maxDepth == 3
    check: dc.maxDelegations == 10
    check: dc.personaName == "explicit"


suite "delegate_enabled TOML defaulting":
  test "persona without delegate_enabled defaults to enabled":
    var reg = newPersonaRegistry()
    let stream = newStringStream("[personas.no_flag]\nsystem_prompt = \"hi\"\n")
    loadPersonasFromStream(reg, stream)
    check: reg.getPersona("no_flag").delegateEnabled == true

  test "persona with delegate_enabled = false stays disabled":
    var reg = newPersonaRegistry()
    let stream = newStringStream(
      "[personas.locked_down]\ndelegate_enabled = false\n")
    loadPersonasFromStream(reg, stream)
    check: reg.getPersona("locked_down").delegateEnabled == false

  test "persona with delegate_enabled = true stays enabled":
    var reg = newPersonaRegistry()
    let stream = newStringStream(
      "[personas.explicit_on]\ndelegate_enabled = true\n")
    loadPersonasFromStream(reg, stream)
    check: reg.getPersona("explicit_on").delegateEnabled == true


suite "System prompt defaults":

  test "persona system prompt is empty by default":
    let pc = PersonaConfig(name: "anon")
    check: pc.systemPrompt.len == 0