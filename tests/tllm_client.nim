## Tests for talos_core/llm_client.nim
##
## Uses a tiny in-process TCP mock server (one connection at a time, sync)
## to exercise the LLM client without depending on Task 2.3's mock server.

import std/[json, os, strutils, tables, unittest]
import talos_core/llm_client
import mock_llm_server

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

const SuccessBody = """
{
  "id": "chatcmpl-1",
  "object": "chat.completion",
  "model": "test-model",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "Hello!"},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10}
}
"""

const ToolCallBody = """
{
  "id": "chatcmpl-2",
  "object": "chat.completion",
  "model": "test-model",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": null,
      "tool_calls": [
        {"id": "call_abc", "type": "function",
         "function": {"name": "shell", "arguments": "{\"cmd\": \"ls\"}"}}
      ]
    },
    "finish_reason": "tool_calls"
  }]
}
"""

const AuthErrBody = """{"error": {"message": "Invalid API key", "code": "invalid_api_key"}}"""
const RateLimitBody = """{"error": {"message": "Too many requests"}}"""
const ServerErrBody = """{"error": {"message": "upstream timeout"}}"""

# ---------------------------------------------------------------------------
# Test setup: a single shared server for all suites
# ---------------------------------------------------------------------------

var sharedServer = startMockServer()

# ---------------------------------------------------------------------------
# Suite: basic chat completion
# ---------------------------------------------------------------------------

suite "chatCompletion basic":
  setup:
    resetMock(sharedServer)

  test "parses content from successful response":
    sharedServer.enqueue("200 OK", SuccessBody)
    let client = makeClient(sharedServer)
    let resp = client.chatCompletion("say hello")
    check resp.content == "Hello!"
    check resp.finishReason == "stop"
    check resp.toolCalls.len == 0
    check resp.usage.promptTokens == 7
    check resp.usage.completionTokens == 3
    check resp.usage.totalTokens == 10
    check resp.model == "test-model"

  test "sends prompt as final user message":
    sharedServer.enqueue("200 OK", SuccessBody)
    let client = makeClient(sharedServer)
    discard client.chatCompletion("hello world")
    check sharedServer.requestCount == 1
    let reqJson = parseJson(sharedServer.requestBodies[0])
    check reqJson["model"].getStr() == "test-model"
    let msgs = reqJson["messages"]
    check msgs.kind == JArray
    check msgs[^1]["role"].getStr() == "user"
    check msgs[^1]["content"].getStr() == "hello world"

  test "appends prompt after history":
    sharedServer.enqueue("200 OK", SuccessBody)
    let client = makeClient(sharedServer)
    let history = @[
      ChatMessage(role: crSystem, content: "you are helpful"),
      ChatMessage(role: crUser, content: "first"),
      ChatMessage(role: crAssistant, content: "ack"),
    ]
    discard client.chatCompletion("second", history = history)
    let reqJson = parseJson(sharedServer.requestBodies[0])
    let msgs = reqJson["messages"]
    check msgs.len == 4
    check msgs[0]["role"].getStr() == "system"
    check msgs[1]["role"].getStr() == "user"
    check msgs[1]["content"].getStr() == "first"
    check msgs[3]["content"].getStr() == "second"

  test "extra params override defaults":
    sharedServer.enqueue("200 OK", SuccessBody)
    var defaults = initTable[string, JsonNode]()
    defaults["temperature"] = %0.2
    let client = newLLMClient(
      baseUrl = baseUrlFor(sharedServer),
      apiKey = "k",
      model = "test-model",
      defaultParams = defaults,
      maxRetries = 1,
      retryBackoffMs = 5,
    )
    var extra = initTable[string, JsonNode]()
    extra["temperature"] = %0.9
    extra["max_tokens"] = %256
    discard client.chatCompletion("hi", extraParams = extra)
    let reqJson = parseJson(sharedServer.requestBodies[0])
    check reqJson["temperature"].getFloat() == 0.9
    check reqJson["max_tokens"].getInt() == 256

# ---------------------------------------------------------------------------
# Suite: tool calls
# ---------------------------------------------------------------------------

suite "chatCompletion tool calls":
  setup:
    resetMock(sharedServer)

  test "parses tool_calls from response":
    sharedServer.enqueue("200 OK", ToolCallBody)
    let client = makeClient(sharedServer)
    let resp = client.chatCompletion("run ls")
    check resp.content == ""
    check resp.finishReason == "tool_calls"
    check resp.toolCalls.len == 1
    let tc = resp.toolCalls[0]
    check tc.id == "call_abc"
    check tc.name == "shell"
    check tc.arguments.contains("\"cmd\"")
    check tc.arguments.contains("ls")

  test "round-trips assistant tool_calls in history":
    sharedServer.enqueue("200 OK", SuccessBody)
    let client = makeClient(sharedServer)
    let history = @[
      ChatMessage(role: crUser, content: "run ls"),
      ChatMessage(
        role: crAssistant,
        content: "",
        toolCalls: @[ToolCall(
          id: "call_abc", name: "shell", arguments: "{\"cmd\":\"ls\"}")]),
      ChatMessage(role: crTool, content: "file1\nfile2",
                  toolCallId: "call_abc", name: "shell"),
    ]
    discard client.chatCompletion("", history = history)
    let req = parseJson(sharedServer.requestBodies[0])
    let msgs = req["messages"]
    check msgs.len == 3
    check msgs[1]["role"].getStr() == "assistant"
    check msgs[1]["tool_calls"].kind == JArray
    check msgs[1]["tool_calls"][0]["id"].getStr() == "call_abc"
    check msgs[1]["tool_calls"][0]["function"]["name"].getStr() == "shell"
    check msgs[2]["role"].getStr() == "tool"
    check msgs[2]["tool_call_id"].getStr() == "call_abc"

# ---------------------------------------------------------------------------
# Suite: error mapping
# ---------------------------------------------------------------------------

suite "chatCompletion errors":
  setup:
    resetMock(sharedServer)

  test "401 raises AuthError":
    sharedServer.enqueue("401 Unauthorized", AuthErrBody)
    let client = makeClient(sharedServer, maxRetries = 1)
    expect AuthError:
      discard client.chatCompletion("hi")

  test "AuthError exposes status code":
    sharedServer.enqueue("401 Unauthorized", AuthErrBody)
    let client = makeClient(sharedServer, maxRetries = 1)
    var caught = false
    try:
      discard client.chatCompletion("hi")
    except AuthError as e:
      caught = true
      check e.statusCode == 401
      check e.msg.contains("Invalid API key")
    check caught

  test "400 raises ClientError, not retried":
    sharedServer.enqueue("400 Bad Request",
      """{"error": {"message": "bad input"}}""")
    let client = makeClient(sharedServer, maxRetries = 3)
    expect ClientError:
      discard client.chatCompletion("hi")
    check sharedServer.requestCount == 1

  test "non-JSON success body raises ProtocolError":
    sharedServer.enqueue("200 OK", "not json at all")
    let client = makeClient(sharedServer, maxRetries = 1)
    expect ProtocolError:
      discard client.chatCompletion("hi")

# ---------------------------------------------------------------------------
# Suite: retry behavior
# ---------------------------------------------------------------------------

suite "chatCompletion retry":
  setup:
    resetMock(sharedServer)

  test "429 triggers retry then succeeds":
    sharedServer.enqueue("429 Too Many Requests", RateLimitBody)
    sharedServer.enqueue("429 Too Many Requests", RateLimitBody)
    sharedServer.enqueue("200 OK", SuccessBody)
    let client = makeClient(sharedServer, maxRetries = 3, backoffMs = 1)
    let resp = client.chatCompletion("hi")
    check resp.content == "Hello!"
    check sharedServer.requestCount == 3

  test "429 exhausts retries and raises RateLimitError":
    sharedServer.enqueue("429 Too Many Requests", RateLimitBody)
    sharedServer.enqueue("429 Too Many Requests", RateLimitBody)
    sharedServer.enqueue("429 Too Many Requests", RateLimitBody)
    let client = makeClient(sharedServer, maxRetries = 3, backoffMs = 1)
    var caught = false
    try:
      discard client.chatCompletion("hi")
    except RateLimitError as e:
      caught = true
      check e.statusCode == 429
    check caught
    check sharedServer.requestCount == 3

  test "500 retries then raises ServerError":
    sharedServer.enqueue("500 Internal Server Error", ServerErrBody)
    sharedServer.enqueue("503 Service Unavailable", ServerErrBody)
    sharedServer.enqueue("502 Bad Gateway", ServerErrBody)
    let client = makeClient(sharedServer, maxRetries = 3, backoffMs = 1)
    expect ServerError:
      discard client.chatCompletion("hi")
    check sharedServer.requestCount == 3

  test "500 then 200 succeeds after retry":
    sharedServer.enqueue("500 Internal Server Error", ServerErrBody)
    sharedServer.enqueue("200 OK", SuccessBody)
    let client = makeClient(sharedServer, maxRetries = 3, backoffMs = 1)
    let resp = client.chatCompletion("hi")
    check resp.content == "Hello!"
    check sharedServer.requestCount == 2

  test "maxRetries=1 does not retry":
    sharedServer.enqueue("429 Too Many Requests", RateLimitBody)
    let client = makeClient(sharedServer, maxRetries = 1, backoffMs = 1)
    expect RateLimitError:
      discard client.chatCompletion("hi")
    check sharedServer.requestCount == 1

# ---------------------------------------------------------------------------
# Suite: request shape
# ---------------------------------------------------------------------------

suite "chatCompletion request shape":
  setup:
    resetMock(sharedServer)

  ## "request body has model/messages keys" isn't covered as its own test:
  ## "sends prompt as final user message" and "appends prompt after
  ## history" above already index into `reqJson["model"]`/`["messages"]`
  ## (which raises if the key is absent) and additionally check the real
  ## values, so a dedicated hasKey-only test would add nothing.

# ---------------------------------------------------------------------------
# Suite: chatCompletionStream (SSE)
# ---------------------------------------------------------------------------

suite "chatCompletionStream":
  setup:
    resetMock(sharedServer)

  test "delivers content deltas via onEvent and aggregates the final text":
    let ev1 = %*{
      "id": "chatcmpl-s1", "model": "test-model",
      "choices": [{"index": 0, "delta": {"content": "Hel"}}]
    }
    let ev2 = %*{
      "id": "chatcmpl-s1", "model": "test-model",
      "choices": [{
        "index": 0, "delta": {"content": "lo!"}, "finish_reason": "stop"
      }],
      "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}
    }
    let body = "data: " & $ev1 & "\n\ndata: " & $ev2 & "\n\ndata: [DONE]\n\n"
    sharedServer.enqueue("200 OK", body)
    let client = makeClient(sharedServer)

    var deltas: seq[string] = @[]
    var finishEvents = 0
    let onEvent = proc(ev: ChatCompletionStreamEvent) {.gcsafe, raises: [].} =
      {.cast(gcsafe), cast(raises: []).}:
        if ev.kind == sekContent:
          deltas.add(ev.delta)
        elif ev.kind == sekFinish:
          inc finishEvents

    let resp = client.chatCompletionStream("say hello", onEvent = onEvent)
    check deltas == @["Hel", "lo!"]
    check finishEvents == 1
    check resp.content == "Hello!"
    check resp.finishReason == "stop"
    check resp.usage.totalTokens == 7

  test "aggregates streamed tool call argument deltas":
    let ev1 = %*{
      "id": "chatcmpl-s2", "model": "test-model",
      "choices": [{"index": 0, "delta": {"tool_calls": [
        {"index": 0, "id": "call_1",
         "function": {"name": "shell", "arguments": "{\"cmd\": "}}
      ]}}]
    }
    let ev2 = %*{
      "id": "chatcmpl-s2", "model": "test-model",
      "choices": [{
        "index": 0,
        "delta": {"tool_calls": [
          {"index": 0, "function": {"arguments": "\"ls\"}"}}
        ]},
        "finish_reason": "tool_calls"
      }]
    }
    let body = "data: " & $ev1 & "\n\ndata: " & $ev2 & "\n\ndata: [DONE]\n\n"
    sharedServer.enqueue("200 OK", body)
    let client = makeClient(sharedServer)

    let resp = client.chatCompletionStream("run ls", onEvent = nil)
    check resp.toolCalls.len == 1
    check resp.toolCalls[0].name == "shell"
    check resp.toolCalls[0].arguments == "{\"cmd\": \"ls\"}"
    check resp.finishReason == "tool_calls"

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

# Stop server at process exit so threads don't linger.
addQuitProc(proc() {.noconv.} = stopMockServer(sharedServer))
