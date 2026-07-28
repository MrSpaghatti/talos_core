import unittest
import std/[os, strutils]
import talos_core/crash_report

suite "RingLogger":
  test "keeps only the most recent N lines":
    var ring = newRingLogger(capacity = 3)
    ring.log("one")
    ring.log("two")
    ring.log("three")
    ring.log("four")
    check ring.recentLines() == @["two", "three", "four"]

  test "empty ring returns empty seq":
    var ring = newRingLogger(capacity = 5)
    check ring.recentLines().len == 0

  test "capacity of zero keeps nothing":
    var ring = newRingLogger(capacity = 0)
    ring.log("dropped")
    check ring.recentLines().len == 0

suite "writeCrashReport":
  test "appends a timestamped report with exception and recent log lines":
    let path = getTempDir() / "talos_test_crash_report" / "latest.log"
    if fileExists(path):
      removeFile(path)
    defer:
      removeFile(path)
      removeDir(path.parentDir)

    var ring = newRingLogger()
    ring.log("connected to gateway")
    ring.log("received message from admin")

    try:
      raise newException(ValueError, "boom")
    except ValueError as e:
      writeCrashReport(path, e, ring)

    check fileExists(path)
    let contents = readFile(path)
    check contents.contains("Talos crash report")
    check contents.contains("ValueError: boom")
    check contents.contains("connected to gateway")
    check contents.contains("received message from admin")

  test "append-only: a second crash doesn't erase the first":
    let path = getTempDir() / "talos_test_crash_report_append" / "latest.log"
    if fileExists(path):
      removeFile(path)
    defer:
      removeFile(path)
      removeDir(path.parentDir)

    var ring = newRingLogger()
    try:
      raise newException(ValueError, "first crash")
    except ValueError as e:
      writeCrashReport(path, e, ring)
    try:
      raise newException(IOError, "second crash")
    except IOError as e:
      writeCrashReport(path, e, ring)

    let contents = readFile(path)
    check contents.contains("first crash")
    check contents.contains("second crash")
