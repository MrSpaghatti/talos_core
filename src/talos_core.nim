## Talos core library barrel re-export.
##
## Note: Most consumers import individual submodules directly
## (e.g. `import talos_core/config`). This barrel exists for
## backward compatibility with the Discord-era module set.
## New modules (config, llm_client, memory, tool_registry, mcp_*,
## persona, delegate) are intentionally not re-exported here
## because they are always imported explicitly.

when isMainModule:
  discard

import talos_core/[agent_dispatcher, discord, discord_bridge, discord_commands, discord_mocks, discord_types, file_path_validator, file_tool, message_chunker, permission, rate_limit, thread_mapping]

export agent_dispatcher, discord, discord_bridge, discord_commands, discord_mocks, discord_types, file_path_validator, file_tool, message_chunker, permission, rate_limit, thread_mapping
