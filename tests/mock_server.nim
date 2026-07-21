import std/[asynchttpserver, asyncdispatch, json, times, net]

type
  MockLLMServer* = ref object
    server*: AsyncHttpServer
    port*: int
    responseDelay*: int
    requestCount*: int
    lastRequestBody*: string

    # Response config
    responseText*: string
    toolCallName*: string
    toolCallArgs*: JsonNode
    errorCode*: int
    errorMessage*: string

proc newMockLLMServer*(): MockLLMServer =
  result = MockLLMServer(
    server: newAsyncHttpServer(),
    port: 0,
    responseDelay: 0,
    requestCount: 0,
    responseText: "",
    toolCallName: "",
    toolCallArgs: nil,
    errorCode: 0,
    errorMessage: ""
  )

proc setResponse*(self: MockLLMServer, text: string) =
  self.responseText = text
  self.toolCallName = ""
  self.toolCallArgs = nil
  self.errorCode = 0
  self.errorMessage = ""

proc setToolCallResponse*(self: MockLLMServer, name: string, args: JsonNode) =
  self.responseText = ""
  self.toolCallName = name
  self.toolCallArgs = args
  self.errorCode = 0
  self.errorMessage = ""

proc setErrorResponse*(self: MockLLMServer, code: int, message: string) =
  self.errorCode = code
  self.errorMessage = message
  self.responseText = ""
  self.toolCallName = ""
  self.toolCallArgs = nil

proc setDelay*(self: MockLLMServer, ms: int) =
  self.responseDelay = ms

proc getRequestCount*(self: MockLLMServer): int =
  self.requestCount

proc getLastRequestBody*(self: MockLLMServer): string =
  self.lastRequestBody

proc handleRequest*(self: MockLLMServer, req: Request) {.async.} =
  self.requestCount += 1
  self.lastRequestBody = req.body

  if self.responseDelay > 0:
    await sleepAsync(self.responseDelay)
    
  if req.url.path != "/v1/chat/completions":
    await req.respond(Http404, "Not Found")
    return
    
  if req.reqMethod != HttpPost:
    await req.respond(Http405, "Method Not Allowed")
    return

  if self.errorCode > 0:
    let errorJson = %*{
      "error": {
        "message": self.errorMessage,
        "type": "mock_error",
        "code": self.errorCode
      }
    }
    let headers = newHttpHeaders([("Content-Type", "application/json")])
    await req.respond(HttpCode(self.errorCode), $errorJson, headers)
    return

  var responseJson: JsonNode
  
  if self.toolCallName != "":
    responseJson = %*{
      "id": "chatcmpl-mock",
      "object": "chat.completion",
      "created": getTime().toUnix(),
      "model": "mock-model",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": newJNull(),
            "tool_calls": [
              {
                "id": "call_mock",
                "type": "function",
                "function": {
                  "name": self.toolCallName,
                  "arguments": $self.toolCallArgs
                }
              }
            ]
          },
          "finish_reason": "tool_calls"
        }
      ]
    }
  else:
    responseJson = %*{
      "id": "chatcmpl-mock",
      "object": "chat.completion",
      "created": getTime().toUnix(),
      "model": "mock-model",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": self.responseText
          },
          "finish_reason": "stop"
        }
      ]
    }
    
  let headers = newHttpHeaders([("Content-Type", "application/json")])
  await req.respond(Http200, $responseJson, headers)

proc start*(self: MockLLMServer) {.async.} =
  # We use port 0 to let OS pick a random free port
  self.server.listen(Port(0))
  self.port = self.server.getPort().int
  
  # Run the server in a background async task
  asyncCheck self.server.acceptRequest(
    proc (req: Request) {.async.} = await self.handleRequest(req)
  )

proc stop*(self: MockLLMServer) =
  self.server.close()
