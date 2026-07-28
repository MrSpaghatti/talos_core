## Tests for talos_core/heartbeat.nim

import std/[unittest, asyncdispatch, options]
import talos_core/heartbeat

suite "Heartbeat":
  test "tick delivers a surfaced message":
    var surfaced: seq[string] = @[]
    let hb = newHeartbeat(1000, proc(msg: string) = surfaced.add(msg))
    hb.addCheck(proc(): Future[Option[string]] {.async.} =
      return some("hello"))
    waitFor hb.tick()
    check surfaced == @["hello"]

  test "tick skips none results":
    var surfaced: seq[string] = @[]
    let hb = newHeartbeat(1000, proc(msg: string) = surfaced.add(msg))
    hb.addCheck(proc(): Future[Option[string]] {.async.} =
      return none(string))
    waitFor hb.tick()
    check surfaced.len == 0

  test "a raising check doesn't stop the others":
    var surfaced: seq[string] = @[]
    let hb = newHeartbeat(1000, proc(msg: string) = surfaced.add(msg))
    hb.addCheck(proc(): Future[Option[string]] {.async.} =
      raise newException(ValueError, "boom"))
    hb.addCheck(proc(): Future[Option[string]] {.async.} =
      return some("still works"))
    waitFor hb.tick()
    check surfaced == @["still works"]

  test "multiple checks run in registration order":
    var surfaced: seq[string] = @[]
    let hb = newHeartbeat(1000, proc(msg: string) = surfaced.add(msg))
    hb.addCheck(proc(): Future[Option[string]] {.async.} =
      return some("first"))
    hb.addCheck(proc(): Future[Option[string]] {.async.} =
      return some("second"))
    waitFor hb.tick()
    check surfaced == @["first", "second"]

  test "run ticks until stop is called":
    var count = 0
    let hb = newHeartbeat(10, proc(msg: string) = discard)
    hb.addCheck(proc(): Future[Option[string]] {.async.} =
      inc count
      return none(string))
    check hb.isRunning == false
    asyncCheck hb.run()
    check hb.isRunning == true
    waitFor sleepAsync(55)
    hb.stop()
    waitFor sleepAsync(20)
    check hb.isRunning == false
    check count >= 3

  test "newHeartbeat rejects non-positive interval":
    expect AssertionDefect:
      discard newHeartbeat(0, proc(msg: string) = discard)
