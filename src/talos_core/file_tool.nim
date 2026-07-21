import json, os
import file_path_validator
import permission
import tool_registry
import discord_types

const MaxFileSize* = 1024 * 1024 # 1MB

proc fileReadTool*(rules: FileRules): Tool =
  let parameters = %*{
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Path to the file to read"
      }
    },
    "required": ["path"]
  }

  let execute = proc (args: JsonNode): ToolResult {.raises: [].} =
    let path = args{"path"}.getStr()
    if path == "":
      return ToolResult(output: "Error: path is required", isError: true, exitCode: 1)

    let val = try: validatePath(path, rules)
              except CatchableError as e:
                return ToolResult(output: "Error validating path: " & e.msg, isError: true, exitCode: 1)
    case val.decision
    of pathDeny:
      return ToolResult(output: "Access denied: " & val.reason, isError: true, exitCode: 1)
    of pathAsk:
      return ToolResult(output: "This path requires approval. Ask an admin.", isError: true, exitCode: 1)
    of pathAllow:
      if not fileExists(val.resolvedPath):
        return ToolResult(output: "Error: file does not exist", isError: true, exitCode: 1)
      let info = try: getFileInfo(val.resolvedPath)
                  except CatchableError as e:
                    return ToolResult(output: "Error getting file info: " & e.msg, isError: true, exitCode: 1)
      if info.size > MaxFileSize:
        return ToolResult(output: "Error: file size exceeds maximum allowed (1MB)", isError: true, exitCode: 1)
      try:
        let content = readFile(val.resolvedPath)
        return ToolResult(output: content, isError: false, exitCode: 0)
      except CatchableError as e:
        return ToolResult(output: "Error reading file: " & e.msg, isError: true, exitCode: 1)
    of pathInvalid:
      return ToolResult(output: "Error: invalid path", isError: true, exitCode: 1)

  result = newTool("file_read", "Read contents of a file", parameters, execute)

proc fileWriteTool*(rules: FileRules, cfg: DiscordConfig, userId: string): Tool =
  let parameters = %*{
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Path to the file to write"
      },
      "content": {
        "type": "string",
        "description": "Content to write to the file"
      }
    },
    "required": ["path", "content"]
  }

  let execute = proc (args: JsonNode): ToolResult {.raises: [].} =
    let path = args{"path"}.getStr()
    let content = args{"content"}.getStr()
    if path == "":
      return ToolResult(output: "Error: path is required", isError: true, exitCode: 1)

    if content.len > MaxFileSize:
      return ToolResult(output: "Error: file size exceeds maximum allowed (1MB)", isError: true, exitCode: 1)

    let val = try: validatePath(path, rules)
              except CatchableError as e:
                return ToolResult(output: "Error validating path: " & e.msg, isError: true, exitCode: 1)
    case val.decision
    of pathDeny:
      return ToolResult(output: "Access denied: " & val.reason, isError: true, exitCode: 1)
    of pathAsk:
      return ToolResult(output: "Requires approval", isError: true, exitCode: 1)
    of pathAllow:
      let perm = canUseTool(userId, "file_write", cfg)
      case perm
      of pdDeny:
        return ToolResult(output: "Access denied: user not allowed", isError: true, exitCode: 1)
      of pdAsk:
        return ToolResult(output: "Requires approval", isError: true, exitCode: 1)
      of pdAllow:
        let parent = parentDir(val.resolvedPath)
        if parent != "" and not dirExists(parent):
          try:
            createDir(parent)
          except CatchableError as e:
            return ToolResult(output: "Error creating directory: " & e.msg, isError: true, exitCode: 1)

        let tempPath = val.resolvedPath & ".tmp"
        try:
          writeFile(tempPath, content)
        except CatchableError as e:
          return ToolResult(output: "Error writing temp file: " & e.msg, isError: true, exitCode: 1)
        try:
          moveFile(tempPath, val.resolvedPath)
          return ToolResult(output: "File written successfully", isError: false, exitCode: 0)
        except CatchableError as e:
          if fileExists(tempPath):
            try: removeFile(tempPath) except CatchableError: discard
          return ToolResult(output: "Error moving file: " & e.msg, isError: true, exitCode: 1)
        # Nim 2.2.x with -d:ssl may flag moveFile as raising Exception transitively.
        # Catch as a safety net even though this should never trigger.
        except Exception as e:
          if fileExists(tempPath):
            try: removeFile(tempPath) except CatchableError: discard
          return ToolResult(output: "Error moving file: " & e.msg, isError: true, exitCode: 1)
    of pathInvalid:
      return ToolResult(output: "Error: invalid path", isError: true, exitCode: 1)

  result = newTool("file_write", "Write content to a file atomically", parameters, execute)
