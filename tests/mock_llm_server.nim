## Shared in-process TCP mock server for exercising LLMClient against real
## blocking socket I/O (chatCompletion/chatCompletionStream use a
## synchronous std/httpclient or raw Socket, not asyncdispatch, so an
## asynchttpserver-based mock can't interleave with them on one thread —
## this one runs in its own OS thread instead).
##
## One connection at a time, synchronous, thread-based.

import std/[net, strutils, locks]
import talos_core/llm_client

type
  MockResponse* = object
    statusLine*: string             ## e.g. "200 OK"
    body*: string
    contentType*: string

  MockServer* = ref object
    socket: Socket
    port*: int
    thread: Thread[MockServer]
    responses: seq[MockResponse]   ## FIFO queue of responses
    requestCount*: int
    requestBodies*: seq[string]
    lock: Lock
    running: bool

# Use globals because Nim threads cannot capture refs from the heap
# trivially across thread boundaries on all platforms.
var gServer: MockServer

proc readRequest(client: Socket): string =
  ## Reads an HTTP request from a connected socket and returns the body.
  ## Returns "" if no body or on parse failure.
  var headerBuf = ""
  while true:
    let line = client.recvLine(timeout = 5000)
    if line.len == 0:
      break
    headerBuf.add(line)
    headerBuf.add("\r\n")
    if line == "\r\n" or line == "":
      break
  # Determine content length
  var contentLength = 0
  for raw in headerBuf.splitLines():
    let lower = raw.toLowerAscii()
    if lower.startsWith("content-length:"):
      let valPart = raw[raw.find(':') + 1 .. ^1].strip()
      try:
        contentLength = parseInt(valPart)
      except ValueError:
        contentLength = 0
  if contentLength <= 0:
    return ""
  var body = newString(contentLength)
  var got = 0
  while got < contentLength:
    let chunk = client.recv(contentLength - got, timeout = 5000)
    if chunk.len == 0:
      break
    body[got ..< got + chunk.len] = chunk
    got += chunk.len
  return body[0 ..< got]

proc sendResponse(client: Socket; resp: MockResponse) =
  let ct = if resp.contentType.len > 0: resp.contentType else: "application/json"
  let payload = "HTTP/1.1 " & resp.statusLine & "\r\n" &
                "Content-Type: " & ct & "\r\n" &
                "Content-Length: " & $resp.body.len & "\r\n" &
                "Connection: close\r\n\r\n" & resp.body
  client.send(payload)

proc serverLoop(srv: MockServer) {.thread.} =
  while srv.running:
    var client: Socket
    try:
      srv.socket.accept(client)
    except OSError, IOError:
      return
    if client.isNil:
      return
    try:
      let body = readRequest(client)
      var resp: MockResponse
      withLock srv.lock:
        srv.requestCount.inc
        srv.requestBodies.add(body)
        if srv.responses.len == 0:
          resp = MockResponse(
            statusLine: "500 Internal Server Error",
            body: """{"error": {"message": "no mock response queued"}}""")
        else:
          resp = srv.responses[0]
          srv.responses.delete(0)
      sendResponse(client, resp)
    except CatchableError:
      discard
    finally:
      try: client.close() except CatchableError: discard

proc startMockServer*(): MockServer =
  result = MockServer(
    socket: newSocket(),
    responses: @[],
    requestBodies: @[],
    requestCount: 0,
    running: true,
  )
  initLock(result.lock)
  result.socket.setSockOpt(OptReuseAddr, true)
  # Bind on an OS-assigned port on loopback only.
  result.socket.bindAddr(Port(0), "127.0.0.1")
  let (_, portObj) = result.socket.getLocalAddr()
  result.port = portObj.int
  result.socket.listen()
  gServer = result
  createThread(result.thread, serverLoop, result)

proc stopMockServer*(srv: MockServer) =
  if not srv.running:
    return
  srv.running = false
  # Connect a dummy client so that accept() in the thread unblocks (the
  # loop will exit because srv.running is now false).  On some platforms
  # close() alone does not reliably wake a blocked accept().
  var dummy = newSocket()
  try:
    dummy.connect("127.0.0.1", Port(srv.port))
  except CatchableError:
    discard
  finally:
    try: dummy.close() except CatchableError: discard
  joinThread(srv.thread)
  try: srv.socket.close() except CatchableError: discard
  deinitLock(srv.lock)

proc enqueue*(srv: MockServer; statusLine, body: string) =
  withLock srv.lock:
    srv.responses.add(MockResponse(statusLine: statusLine, body: body))

proc resetMock*(srv: MockServer) =
  withLock srv.lock:
    srv.responses.setLen(0)
    srv.requestBodies.setLen(0)
    srv.requestCount = 0

proc baseUrlFor*(srv: MockServer): string =
  "http://127.0.0.1:" & $srv.port & "/v1"

proc makeClient*(server: MockServer; maxRetries = 3; backoffMs = 5): LLMClient =
  newLLMClient(
    baseUrl = baseUrlFor(server),
    apiKey = "test-key",
    model = "test-model",
    maxRetries = maxRetries,
    retryBackoffMs = backoffMs,
    timeoutMs = 5_000,
  )
