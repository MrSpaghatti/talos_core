import unittest, os, json, strutils
import talos_core/discord_types
import talos_core/file_path_validator
import talos_core/permission
import talos_core/tool_registry
import talos_core/file_tool

suite "File Tool":
  setup:
    let sandboxDir = getCurrentDir() / "test_file_tool_sandbox"
    createDir(sandboxDir)
    let rules = FileRules(
      sandboxDir: sandboxDir,
      allowPatterns: @["*.txt"],
      askPatterns: @["*.md"],
      denyPatterns: @["*.secret"]
    )
    
    var cfg = defaultDiscordConfig()
    cfg.admins.allow.add("admin")
    cfg.users.allow.add("user")

  teardown:
    removeDir(sandboxDir)

  test "fileReadTool returns Tool":
    let t = fileReadTool(rules)
    check t.name == "file_read"

  test "fileReadTool allow":
    let path = sandboxDir / "hello.txt"
    writeFile(path, "hello world")
    
    let t = fileReadTool(rules)
    let args = %*{"path": path}
    let res = t.execute(args)
    check res.isError == false
    check res.output == "hello world"

  test "fileReadTool deny":
    let path = sandboxDir / "file.secret"
    let t = fileReadTool(rules)
    let args = %*{"path": path}
    let res = t.execute(args)
    check res.isError == true
    check res.output.contains("Access denied")

  test "fileReadTool ask":
    let path = sandboxDir / "file.md"
    let t = fileReadTool(rules)
    let args = %*{"path": path}
    let res = t.execute(args)
    check res.isError == true
    check res.output == "This path requires approval. Ask an admin."

  test "fileReadTool missing file":
    let path = sandboxDir / "missing.txt"
    let t = fileReadTool(rules)
    let args = %*{"path": path}
    let res = t.execute(args)
    check res.isError == true

  test "fileWriteTool admin can write to allowed path":
    let path = sandboxDir / "test.txt"
    let t = fileWriteTool(rules, cfg, "admin")
    let args = %*{"path": path, "content": "hello admin"}
    let res = t.execute(args)
    check res.isError == false
    check readFile(path) == "hello admin"

  test "fileWriteTool normal user gets ask on allowed path":
    let path = sandboxDir / "test2.txt"
    let t = fileWriteTool(rules, cfg, "user")
    let args = %*{"path": path, "content": "hello user"}
    let res = t.execute(args)
    check res.isError == true
    check res.output == "Requires approval"

  test "fileWriteTool deny":
    let path = sandboxDir / "test.secret"
    let t = fileWriteTool(rules, cfg, "admin")
    let args = %*{"path": path, "content": "atomic"}
    let res = t.execute(args)
    check res.isError == true
    check res.output.contains("Access denied")

  test "fileWriteTool honors explicit tools.deny by canonical name":
    # The tool registers as "file_write"; the permission check must query the
    # same name so an admin's tools.deny entry is enforced (regression: it
    # previously queried "write_file" and silently bypassed this deny).
    var denyCfg = cfg
    denyCfg.tools.deny.add("file_write")
    let path = sandboxDir / "denied.txt"
    let t = fileWriteTool(rules, denyCfg, "admin")
    let args = %*{"path": path, "content": "should not be written"}
    let res = t.execute(args)
    check res.isError == true
    check res.output.contains("Access denied")
    check (not fileExists(path))

  test "fileWriteTool size limit":
    let path = sandboxDir / "big.txt"
    let t = fileWriteTool(rules, cfg, "admin")
    let bigContent = newString(1024 * 1024 * 2) # 2MB
    let args = %*{"path": path, "content": bigContent}
    let res = t.execute(args)
    check res.isError == true
    check res.output.contains("exceeds")
