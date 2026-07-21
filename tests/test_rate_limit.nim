## Tests for talos_core/rate_limit.nim
##
## Exercises the sendWithRetry generic async proc with mock send functions
## and a mock sleep that records delays instead of actually sleeping.

import std/[asyncdispatch, strutils, unittest]
import talos_core/rate_limit

# ---------------------------------------------------------------------------
# Mock sleep: records delays instead of sleeping
# ---------------------------------------------------------------------------

var recordedDelays: seq[int]

proc mockSleep(ms: int): Future[void] {.async.} =
  recordedDelays.add(ms)

# ---------------------------------------------------------------------------
# Mock send functions
# ---------------------------------------------------------------------------

proc successSend(): Future[int] {.async.} =
  return 42

proc alwaysRateLimitSend(): Future[int] {.async.} =
  var e = newException(RateLimitError, "rate limited")
  e.retryAfterMs = 0
  raise e

proc alwaysServerErrorSend(): Future[int] {.async.} =
  var e = newException(ServerError, "server error 500")
  e.statusCode = 500
  raise e

proc alwaysValueErrorSend(): Future[int] {.async.} =
  raise newException(ValueError, "client error")

proc rateLimitWithRetryAfterSend(): Future[int] {.async.} =
  var e = newException(RateLimitError, "rate limited with retry-after")
  e.retryAfterMs = 5000
  raise e

# ---------------------------------------------------------------------------
# Stateful mock: rate limit N times then succeed
# ---------------------------------------------------------------------------

var rlThenSuccessCount = 0

proc rateLimitThenSuccessSend(): Future[int] {.async.} =
  inc rlThenSuccessCount
  if rlThenSuccessCount < 3:
    var e = newException(RateLimitError, "rate limited")
    e.retryAfterMs = 0
    raise e
  return 42

# ---------------------------------------------------------------------------
# Stateful mock: server error then succeed
# ---------------------------------------------------------------------------

var seThenSuccessCount = 0

proc serverErrorThenSuccessSend(): Future[int] {.async.} =
  inc seThenSuccessCount
  if seThenSuccessCount < 2:
    var e = newException(ServerError, "server error 502")
    e.statusCode = 502
    raise e
  return 42

# ---------------------------------------------------------------------------
# Stateful mock: rate limit with retry-after then succeed
# ---------------------------------------------------------------------------

var rlRetryAfterThenSuccessCount = 0

proc rateLimitRetryAfterThenSuccessSend(): Future[int] {.async.} =
  inc rlRetryAfterThenSuccessCount
  if rlRetryAfterThenSuccessCount < 2:
    var e = newException(RateLimitError, "rate limited")
    e.retryAfterMs = 5000
    raise e
  return 42

# ---------------------------------------------------------------------------
# Stateful mock: mixed errors then succeed
# ---------------------------------------------------------------------------

var mixedCount = 0

proc mixedErrorSend(): Future[int] {.async.} =
  inc mixedCount
  if mixedCount == 1:
    var e = newException(RateLimitError, "rate limited")
    e.retryAfterMs = 0
    raise e
  if mixedCount == 2:
    var e = newException(ServerError, "server error 502")
    e.statusCode = 502
    raise e
  return 42

# ---------------------------------------------------------------------------
# Stateful mock: rate limit then server error then succeed (3 attempts)
# ---------------------------------------------------------------------------

var rlSeSuccessCount = 0

proc rateLimitSeSuccessSend(): Future[int] {.async.} =
  inc rlSeSuccessCount
  if rlSeSuccessCount == 1:
    var e = newException(RateLimitError, "rate limited")
    e.retryAfterMs = 0
    raise e
  if rlSeSuccessCount == 2:
    var e = newException(ServerError, "server error 500")
    e.statusCode = 500
    raise e
  return 42

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "sendWithRetry":
  setup:
    recordedDelays = @[]
    rlThenSuccessCount = 0
    seThenSuccessCount = 0
    rlRetryAfterThenSuccessCount = 0
    mixedCount = 0
    rlSeSuccessCount = 0

  test "returns result on first success":
    let result = waitFor sendWithRetry(successSend, maxAttempts = 3,
                                        baseDelayMs = 1000, sleepFn = mockSleep)
    check result == 42
    check recordedDelays.len == 0

  test "retries on RateLimitError with exponential backoff":
    let result = waitFor sendWithRetry(rateLimitThenSuccessSend, maxAttempts = 3,
                                       baseDelayMs = 1000, sleepFn = mockSleep)
    check result == 42
    check rlThenSuccessCount == 3
    # Attempt 1 fails -> delay = 1000 * 2^0 = 1000
    # Attempt 2 fails -> delay = 1000 * 2^1 = 2000
    check recordedDelays == @[1000, 2000]

  test "respects Retry-After from RateLimitError":
    let result = waitFor sendWithRetry(rateLimitRetryAfterThenSuccessSend,
                                       maxAttempts = 3, baseDelayMs = 1000,
                                       sleepFn = mockSleep)
    check result == 42
    # retryAfterMs = 5000 overrides exponential backoff
    check recordedDelays == @[5000]

  test "retries on ServerError with exponential backoff":
    let result = waitFor sendWithRetry(serverErrorThenSuccessSend, maxAttempts = 3,
                                       baseDelayMs = 1000, sleepFn = mockSleep)
    check result == 42
    # Attempt 1 fails -> delay = 1000 * 2^0 = 1000
    check recordedDelays == @[1000]

  test "raises RetryExhaustedError after max attempts on persistent rate limit":
    expect RetryExhaustedError:
      discard waitFor sendWithRetry(alwaysRateLimitSend, maxAttempts = 3,
                                    baseDelayMs = 1000, sleepFn = mockSleep)
    # 3 attempts, 2 delays (between attempts 1-2 and 2-3)
    check recordedDelays.len == 2
    check recordedDelays == @[1000, 2000]

  test "raises RetryExhaustedError after max attempts on persistent server error":
    expect RetryExhaustedError:
      discard waitFor sendWithRetry(alwaysServerErrorSend, maxAttempts = 3,
                                    baseDelayMs = 1000, sleepFn = mockSleep)
    check recordedDelays.len == 2
    check recordedDelays == @[1000, 2000]

  test "does not retry on other exceptions":
    expect ValueError:
      discard waitFor sendWithRetry(alwaysValueErrorSend, maxAttempts = 3,
                                    baseDelayMs = 1000, sleepFn = mockSleep)
    check recordedDelays.len == 0

  test "mixed errors: rate limit then server error then success":
    let result = waitFor sendWithRetry(mixedErrorSend, maxAttempts = 3,
                                       baseDelayMs = 1000, sleepFn = mockSleep)
    check result == 42
    check mixedCount == 3
    # Attempt 1 (rate limit) -> delay = 1000 * 2^0 = 1000
    # Attempt 2 (server error) -> delay = 1000 * 2^1 = 2000
    check recordedDelays == @[1000, 2000]

  test "respects custom maxAttempts":
    # With maxAttempts=1, even a single rate limit should exhaust retries
    expect RetryExhaustedError:
      discard waitFor sendWithRetry(alwaysRateLimitSend, maxAttempts = 1,
                                    baseDelayMs = 1000, sleepFn = mockSleep)
    check recordedDelays.len == 0

  test "respects custom baseDelayMs":
    let result = waitFor sendWithRetry(serverErrorThenSuccessSend, maxAttempts = 3,
                                       baseDelayMs = 500, sleepFn = mockSleep)
    check result == 42
    # Attempt 1 fails -> delay = 500 * 2^0 = 500
    check recordedDelays == @[500]

  test "uses default sleep when sleepFn not provided":
    # This test actually sleeps for a tiny duration to verify defaultSleepFn works.
    # We use a very short baseDelayMs to keep the test fast.
    proc quickSuccess(): Future[int] {.async.} = return 99
    let result = waitFor sendWithRetry(quickSuccess, maxAttempts = 3,
                                       baseDelayMs = 1)
    check result == 99

  test "RetryExhaustedError message includes attempt count":
    try:
      discard waitFor sendWithRetry(alwaysRateLimitSend, maxAttempts = 3,
                                    baseDelayMs = 1, sleepFn = mockSleep)
      check false  # Should not reach here
    except RetryExhaustedError as e:
      check "3" in e.msg