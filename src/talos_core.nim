## Talos core library barrel re-export.
##
## Note: Most consumers import individual submodules directly
## (e.g. `import talos_core/config`). This barrel exists for
## backward compatibility with the Discord-era module set.
## New modules (config, llm_client, memory, tool_registry, mcp_*,
## persona, delegate) are intentionally not re-exported here
## because they are always imported explicitly.
##
## Discord-specific modules (discord, discord_bridge, discord_commands,
## discord_mocks, discord_types, thread_mapping) moved to talos_agent —
## core has no product baked in.

when isMainModule:
  discard

import talos_core/[acl, agent_dispatcher, file_path_validator, file_tool, message_chunker, permission]

export acl, agent_dispatcher, file_path_validator, file_tool, message_chunker, permission
