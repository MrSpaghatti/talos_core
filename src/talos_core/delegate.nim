const
  DefaultMaxDelegationDepth* = 2
  DefaultMaxDelegationsPerRun* = 5

type
  DelegationConfig* = object
    maxDepth*: int
    maxDelegations*: int
    personaName*: string

proc defaultDelegationConfig*(): DelegationConfig =
  DelegationConfig(
    maxDepth: DefaultMaxDelegationDepth,
    maxDelegations: DefaultMaxDelegationsPerRun,
    personaName: "",
  )

proc canDelegate*(dc: DelegationConfig): bool =
  dc.maxDepth > 0 and dc.maxDelegations > 0

proc useDelegationSlot*(dc: var DelegationConfig) =
  dec dc.maxDepth
  dec dc.maxDelegations

proc applyPersonaDelegation*(
    maxDelegationDepth: int;
    maxDelegationsPerRun: int;
    personaName: string;
    parentMaxDepth: int = -1;
): DelegationConfig =
  ## `parentMaxDepth`, when >= 0, caps the result to
  ## `min(persona's own limit, parentMaxDepth - 1)` — the parent's
  ## *remaining* depth budget for this delegation chain, minus one for the
  ## hop being spawned right now. Without this, a child's depth is derived
  ## purely from its own persona's configured limit, so `maxDepth` resets
  ## at every hop instead of being a real chain-wide bound: two personas
  ## that delegate back and forth could recurse far deeper than any single
  ## `maxDepth` setting implies. Pass -1 (the default) for a top-level
  ## agent that has no parent delegation chain to inherit from.
  let personaDepth =
    if maxDelegationDepth > 0: maxDelegationDepth
    else: DefaultMaxDelegationDepth
  let depth =
    if parentMaxDepth >= 0: min(personaDepth, max(parentMaxDepth - 1, 0))
    else: personaDepth
  DelegationConfig(
    maxDepth: depth,
    maxDelegations: if maxDelegationsPerRun > 0: maxDelegationsPerRun
                    else: DefaultMaxDelegationsPerRun,
    personaName: personaName,
  )