## Talos rate limit handler with exponential backoff.
##
## Provides a generic retry mechanism for Discord API rate limit handling.
## - Retries on 429 (rate limit) with exponential backoff
## - Respects Retry-After header value from Discord API responses
## - Retries on 5xx (server error) with exponential backoff
## - Max attempts configurable (default 3)
## - Does NOT retry 4xx errors (except 429)
##
## The caller is responsible for translating Discord API errors into
## RateLimitError / ServerError exceptions with appropriate fields set.
## This keeps the module generic and independent of any specific HTTP client.

import std/asyncdispatch

type
  RateLimitError* = object of CatchableError
    ## Raised when the API returns a 429 Too Many Requests response.
    ## Set retryAfterMs to the value from the Retry-After header (in ms).
    ## When retryAfterMs > 0, sendWithRetry uses it instead of exponential backoff.
    retryAfterMs*: int

  ServerError* = object of CatchableError
    ## Raised when the API returns a 5xx server error response.
    statusCode*: int

  RetryExhaustedError* = object of CatchableError
    ## Raised when all retry attempts have been exhausted.

  SleepFn* = proc(ms: int): Future[void]

proc defaultSleepFn*(ms: int): Future[void] {.async.} =
  ## Default sleep function using asyncdispatch.sleepAsync.
  await sleepAsync(ms)

proc sendWithRetry*[T](
  sendFn: proc(): Future[T],
  maxAttempts = 3,
  baseDelayMs = 1000,
  sleepFn: SleepFn = nil
): Future[T] {.async.} =
  ## Sends a request with retry logic for rate limits and server errors.
  ##
  ## Parameters:
  ##   sendFn      - Async proc that performs the API call and returns a value
  ##                 or raises RateLimitError / ServerError on retryable failures.
  ##   maxAttempts - Maximum number of attempts (default 3).
  ##   baseDelayMs - Base delay in ms for exponential backoff (default 1000).
  ##                 Delay = baseDelayMs * 2^(attempt-1).
  ##   sleepFn    - Optional sleep function for testing. Defaults to sleepAsync.
  ##
  ## Behavior:
  ##   - On RateLimitError: if retryAfterMs > 0, uses that value as delay;
  ##     otherwise uses exponential backoff.
  ##   - On ServerError: uses exponential backoff.
  ##   - Other exceptions: re-raised immediately (no retry).
  ##   - After maxAttempts: raises RetryExhaustedError.
  let slp = if sleepFn.isNil: defaultSleepFn else: sleepFn

  var attempt = 0
  while attempt < maxAttempts:
    inc attempt
    try:
      return await sendFn()
    except RateLimitError as e:
      if attempt >= maxAttempts:
        raise newException(RetryExhaustedError,
          "Rate limit retry exhausted after " & $maxAttempts & " attempts: " & e.msg)
      let delay = if e.retryAfterMs > 0: e.retryAfterMs
                  else: baseDelayMs * (1 shl (attempt - 1))
      await slp(delay)
    except ServerError as e:
      if attempt >= maxAttempts:
        raise newException(RetryExhaustedError,
          "Server error retry exhausted after " & $maxAttempts & " attempts: " & e.msg)
      let delay = baseDelayMs * (1 shl (attempt - 1))
      await slp(delay)

  raise newException(RetryExhaustedError,
    "Retry exhausted after " & $maxAttempts & " attempts")