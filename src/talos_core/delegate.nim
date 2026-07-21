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
): DelegationConfig =
  DelegationConfig(
    maxDepth: if maxDelegationDepth > 0: maxDelegationDepth
              else: DefaultMaxDelegationDepth,
    maxDelegations: if maxDelegationsPerRun > 0: maxDelegationsPerRun
                    else: DefaultMaxDelegationsPerRun,
    personaName: personaName,
  )