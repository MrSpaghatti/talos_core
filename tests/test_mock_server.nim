import std/[asyncdispatch, httpclient, json, unittest, net]
import mock_server

suite "MockLLMServer":
  test "returns basic text response":
    let server = newMockLLMServer()
    server.setResponse("Hello, world!")
    waitFor server.start()

    let client = newAsyncHttpClient()
    let response = waitFor client.post("http://127.0.0.1:" & $server.port & "/v1/chat/completions", body = "{}")
    check response.code == Http200
    
    let body = waitFor response.body
    let jsonBody = parseJson(body)
    check jsonBody["choices"][0]["message"]["content"].getStr() == "Hello, world!"
    check server.getRequestCount() == 1
    
    client.close()

  test "returns tool call response":
    let server = newMockLLMServer()
    let args = %*{"arg1": "value1"}
    server.setToolCallResponse("my_tool", args)
    waitFor server.start()

    let client = newAsyncHttpClient()
    let response = waitFor client.post("http://127.0.0.1:" & $server.port & "/v1/chat/completions", body = "{}")
    check response.code == Http200
    
    let body = waitFor response.body
    let jsonBody = parseJson(body)
    let toolCall = jsonBody["choices"][0]["message"]["tool_calls"][0]["function"]
    check toolCall["name"].getStr() == "my_tool"
    check toolCall["arguments"].getStr() == $args
    
    client.close()

  test "returns error response":
    let server = newMockLLMServer()
    server.setErrorResponse(400, "Bad Request")
    waitFor server.start()

    let client = newAsyncHttpClient()
    let response = waitFor client.post("http://127.0.0.1:" & $server.port & "/v1/chat/completions", body = "{}")
    check response.code == Http400
    
    let body = waitFor response.body
    let jsonBody = parseJson(body)
    check jsonBody["error"]["message"].getStr() == "Bad Request"
    
    client.close()
