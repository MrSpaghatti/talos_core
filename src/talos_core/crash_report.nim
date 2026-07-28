## Crash reporting: a fixed-capacity ring buffer of recent log lines, plus a
## writer that appends a durable, timestamped crash report to disk. Exists
## so a daemon crash leaves a diagnosable trail even when nobody's watching
## the terminal (or systemd journal) it was running under at the time.

import std/[times, os, deques]

type
  RingLogger* = ref object
    capacity: int
    lines: Deque[string]

proc newRingLogger*(capacity: int = 200): RingLogger =
  RingLogger(capacity: capacity, lines: initDeque[string]())

proc log*(ring: RingLogger; line: string) =
  ring.lines.addLast(line)
  while ring.lines.len > ring.capacity:
    discard ring.lines.popFirst()

proc recentLines*(ring: RingLogger): seq[string] =
  for line in ring.lines:
    result.add(line)

proc defaultCrashReportPath*(): string =
  getHomeDir() / ".local" / "share" / "talos" / "crash_reports" / "latest.log"

proc writeCrashReport*(path: string; exc: ref Exception; ring: RingLogger) =
  ## Appends a timestamped crash report (exception, stack trace, recent log
  ## lines) to `path`. Append-only — a crash loop accumulates a history in
  ## `latest.log` rather than each crash clobbering the last, so an earlier
  ## (possibly more informative) failure isn't erased by a later one.
  createDir(path.parentDir)
  var f: File
  if not open(f, path, fmAppend):
    return
  defer: f.close()
  f.writeLine("=== Talos crash report: " & $now() & " ===")
  f.writeLine("Exception: " & $exc.name & ": " & exc.msg)
  f.writeLine("Stack trace:")
  f.writeLine(exc.getStackTrace())
  let recent = ring.recentLines()
  f.writeLine("Recent log (last " & $recent.len & " lines):")
  for line in recent:
    f.writeLine("  " & line)
  f.writeLine("")
