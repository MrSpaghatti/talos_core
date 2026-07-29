import unittest, os, json, strutils
import talos_core/acl
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
    
    var acl = ToolAcl()
    acl.admins.allow.add("admin")
    acl.users.allow.add("user")

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
    let t = fileWriteTool(rules, acl)
    let args = %*{"path": path, "content": "hello admin", "_callerId": "admin"}
    let res = t.execute(args)
    check res.isError == false
    check readFile(path) == "hello admin"

  test "fileWriteTool normal user gets ask on allowed path":
    let path = sandboxDir / "test2.txt"
    let t = fileWriteTool(rules, acl)
    let args = %*{"path": path, "content": "hello user", "_callerId": "user"}
    let res = t.execute(args)
    check res.isError == true
    check res.output == "Requires approval"

  test "fileWriteTool deny":
    let path = sandboxDir / "test.secret"
    let t = fileWriteTool(rules, acl)
    let args = %*{"path": path, "content": "atomic", "_callerId": "admin"}
    let res = t.execute(args)
    check res.isError == true
    check res.output.contains("Access denied")

  test "fileWriteTool honors explicit tools.deny by canonical name":
    # The tool registers as "file_write"; the permission check must query the
    # same name so an admin's tools.deny entry is enforced (regression: it
    # previously queried "write_file" and silently bypassed this deny).
    var denyAcl = acl
    denyAcl.tools.deny.add("file_write")
    let path = sandboxDir / "denied.txt"
    let t = fileWriteTool(rules, denyAcl)
    let args = %*{"path": path, "content": "should not be written", "_callerId": "admin"}
    let res = t.execute(args)
    check res.isError == true
    check res.output.contains("Access denied")
    check (not fileExists(path))

  test "fileWriteTool size limit":
    let path = sandboxDir / "big.txt"
    let t = fileWriteTool(rules, acl)
    let bigContent = newString(1024 * 1024 * 2) # 2MB
    let args = %*{"path": path, "content": bigContent, "_callerId": "admin"}
    let res = t.execute(args)
    check res.isError == true
    check res.output.contains("exceeds")

# ---------------------------------------------------------------------------
# Suite: fileReadTool structural summarization (task-18)
# ---------------------------------------------------------------------------

proc genNimProc(n: int): string =
  "proc genned" & $n & "*(): int =\n  var x = " & $n & "\n  x += 1\n  return x\n\n"

suite "fileReadTool: structural summarization":
  setup:
    let sandboxDir = getCurrentDir() / "test_file_tool_summarize_sandbox"
    createDir(sandboxDir)
    let rules = FileRules(
      sandboxDir: sandboxDir,
      allowPatterns: @["*.nim", "*.txt"],
      askPatterns: @[],
      denyPatterns: @[],
    )

  teardown:
    removeDir(sandboxDir)

  test "a file at or below the threshold is returned in full, unchanged":
    let path = sandboxDir / "small.nim"
    writeFile(path, "proc small*(): int =\n  42\n")
    let t = fileReadTool(rules, summarizeThresholdLines = 200)
    let res = t.execute(%*{"path": path})
    check res.isError == false
    check res.output == "proc small*(): int =\n  42\n"
    check not res.output.contains("structural summary")

  test "a file above the threshold is returned as a structural summary by default":
    var content = ""
    for i in 0 ..< 20:
      content.add(genNimProc(i))
    let path = sandboxDir / "big.nim"
    writeFile(path, content)
    let t = fileReadTool(rules, summarizeThresholdLines = 10)
    let res = t.execute(%*{"path": path})
    check res.isError == false
    check res.output.contains("structural summary")
    check res.output.contains("proc genned0*(): int =")
    check not res.output.contains("x += 1")

  test "full=true bypasses summarization even for a large file":
    var content = ""
    for i in 0 ..< 20:
      content.add(genNimProc(i))
    let path = sandboxDir / "big2.nim"
    writeFile(path, content)
    let t = fileReadTool(rules, summarizeThresholdLines = 10)
    let res = t.execute(%*{"path": path, "full": true})
    check res.isError == false
    check res.output == content
    check res.output.contains("x += 1")

  test "an unrecognized extension above the threshold is still returned in full":
    var content = ""
    for i in 0 ..< 20:
      content.add("line " & $i & "\n")
    let path = sandboxDir / "big.txt"
    writeFile(path, content)
    let t = fileReadTool(rules, summarizeThresholdLines = 10)
    let res = t.execute(%*{"path": path})
    check res.isError == false
    check res.output == content

  test "the threshold is configurable: a lower threshold summarizes a file a higher one wouldn't":
    var content = ""
    for i in 0 ..< 5:
      content.add(genNimProc(i))
    let path = sandboxDir / "medium.nim"
    writeFile(path, content)
    let lowThreshold = fileReadTool(rules, summarizeThresholdLines = 5)
    let highThreshold = fileReadTool(rules, summarizeThresholdLines = 1000)
    check lowThreshold.execute(%*{"path": path}).output.contains("structural summary")
    check not highThreshold.execute(%*{"path": path}).output.contains("structural summary")
