## Proactive heartbeat: a minimal interval-tick scheduler that periodically
## asks a set of registered checks whether there's anything worth surfacing
## to the user unprompted (e.g. "you asked me to remind you about X").
##
## v1 ships with the mechanism proven and no real checks registered by
## default — deciding *what's* worth proactively surfacing is a follow-on
## once the plumbing exists, not a blocker to landing the plumbing itself.

import std/[asyncdispatch, options]

type
  SurfaceCheck* = proc(): Future[Option[string]] {.closure.}
    ## A single proactive check, run once per tick. Returns `some(message)`
    ## if something is worth surfacing right now, `none` otherwise. A check
    ## that raises is treated the same as a `none` result — one broken
    ## check must not take down the heartbeat loop or the others sharing it.

  SurfaceFn* = proc(message: string) {.closure.}
    ## Delivers a surfaced message (e.g. DMs the configured admin). Called
    ## once per non-none check result, in registration order.

  Heartbeat* = ref object
    intervalMs: int
    checks: seq[SurfaceCheck]
    surface: SurfaceFn
    running: bool

proc newHeartbeat*(intervalMs: int; surface: SurfaceFn): Heartbeat =
  doAssert intervalMs > 0, "heartbeat interval must be positive"
  Heartbeat(intervalMs: intervalMs, checks: @[], surface: surface, running: false)

proc addCheck*(hb: Heartbeat; check: SurfaceCheck) =
  hb.checks.add(check)

proc isRunning*(hb: Heartbeat): bool = hb.running

proc tick*(hb: Heartbeat): Future[void] {.async.} =
  ## Runs every registered check once, delivering any non-none result via
  ## `surface`. Exposed standalone (not just via `run`) so tests can drive
  ## individual ticks without an interval-sleeping loop.
  for check in hb.checks:
    var msgOpt: Option[string]
    try:
      msgOpt = await check()
    except CatchableError:
      msgOpt = none(string)
    if msgOpt.isSome:
      hb.surface(msgOpt.get())

proc run*(hb: Heartbeat) {.async.} =
  ## Ticks every `intervalMs` until `stop` is called. Intended to be started
  ## with `asyncCheck` alongside the main event loop (e.g. the Discord
  ## gateway session) — it never blocks its caller.
  hb.running = true
  while hb.running:
    await sleepAsync(hb.intervalMs)
    if not hb.running:
      break
    await hb.tick()

proc stop*(hb: Heartbeat) =
  hb.running = false
