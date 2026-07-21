import unittest, os, strutils, uri
import ../src/talos_core/file_path_validator

suite "File Path Validator":
  setup:
    let sandboxDir = getCurrentDir() / "test_sandbox"
    createDir(sandboxDir)
    let rules = FileRules(
      sandboxDir: sandboxDir,
      allowPatterns: @["*.txt", "docs/*"],
      askPatterns: @["*.md"],
      denyPatterns: @[]
    )

  teardown:
    removeDir(sandboxDir)

  test "URL decoding":
    let path = "%2e%2e%2fetc%2fpasswd"
    let decoded = decodeUrl(path)
    check decoded == "../etc/passwd"

  test "Basic absolute path within sandbox":
    let path = sandboxDir / "file.txt"
    let res = validatePath(path, rules)
    check res.decision == pathAllow

  test "Path traversal outside sandbox":
    let path = sandboxDir / ".." / "etc" / "passwd"
    let res = validatePath(path, rules)
    check res.decision == pathDeny
    check res.reason.contains("sandbox")

  test "Sibling directory sharing sandbox prefix cannot escape":
    # /…/test_sandbox-evil/file.txt shares the "test_sandbox" prefix but is
    # NOT inside the sandbox. A naive startsWith check would let it through.
    let evilDir = getCurrentDir() / "test_sandbox-evil"
    createDir(evilDir)
    let path = evilDir / "file.txt"
    let res = validatePath(path, rules)
    check res.decision == pathDeny
    check res.reason.contains("sandbox")
    removeDir(evilDir)

  test "Mandatory deny list takes precedence":
    let path = sandboxDir / ".env"
    let res = validatePath(path, rules)
    check res.decision == pathDeny
    check res.reason.contains("mandatory deny")
    
  test "Mandatory deny list for SSH":
    let path = sandboxDir / ".ssh" / "id_rsa"
    let res = validatePath(path, rules)
    check res.decision == pathDeny
    
  test "Symlink outside sandbox":
    let outDir = getCurrentDir() / "test_out"
    createDir(outDir)
    let symlinkPath = sandboxDir / "link"
    createSymlink(outDir, symlinkPath)
    
    let path = symlinkPath / "file.txt"
    let res = validatePath(path, rules)
    check res.decision == pathDeny
    check res.reason.contains("sandbox")
    
    removeFile(symlinkPath)
    removeDir(outDir)

  test "Symlink to nonexistent file in sandbox":
    let path = sandboxDir / "docs" / "nonexistent.txt"
    let res = validatePath(path, rules)
    check res.decision == pathAllow

  test "Ask pattern match":
    let path = sandboxDir / "readme.md"
    let res = validatePath(path, rules)
    check res.decision == pathAsk

  test "Adversarial URL encoding and path traversal":
    let path = sandboxDir / "%2e%2e%2f%2e%2e%2fetc%2fshadow"
    let res = validatePath(path, rules)
    check res.decision == pathDeny
    check res.reason.contains("sandbox")

  test "Allow list overrides with directory":
    let path = sandboxDir / "docs" / "secret.pdf"
    let res = validatePath(path, rules)
    check res.decision == pathAllow

  test "Symlink traversal attack":
    let outDir = getCurrentDir() / "test_out2"
    createDir(outDir)
    let secretFile = outDir / "secret.txt"
    writeFile(secretFile, "secret")

    let innerDir = sandboxDir / "inner"
    createDir(innerDir)
    let symlinkPath = innerDir / "link"
    createSymlink(outDir, symlinkPath)
    
    let path = symlinkPath / "secret.txt"
    let res = validatePath(path, rules)
    check res.decision == pathDeny
    
    removeFile(symlinkPath)
    removeDir(innerDir)
    removeFile(secretFile)
    removeDir(outDir)
