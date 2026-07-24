## Tests for talos_core/message_chunker.nim

import std/[strutils, unittest]
import talos_core/message_chunker

proc fenceBalanced(chunk: string): bool =
  count(chunk, "```") mod 2 == 0

suite "chunkMessage":
  test "empty string returns no chunks":
    check chunkMessage("") == newSeq[string]()

  test "single character stays intact":
    check chunkMessage("a") == @["a"]

  test "exact maxLen returns one chunk":
    let text = "x".repeat(12)
    let chunks = chunkMessage(text, 12)
    check chunks == @[text]

  test "splits on newline boundaries when possible":
    let chunks = chunkMessage("aaaaa\nbbbbb", 6)
    check chunks == @["aaaaa\n", "bbbbb"]

  test "keeps code fences balanced across chunks":
    let text = "prefix\n```nim\nlet a = \"" & "x".repeat(24) & "\"\nlet b = \"" &
               "y".repeat(24) & "\"\n```\nsuffix"
    let chunks = chunkMessage(text, 30)
    check chunks.len > 1
    var sawContinuation = false
    for chunk in chunks:
      check chunk.len <= 30
      check fenceBalanced(chunk)
      if chunk.contains("..."):
        sawContinuation = true
    check sawContinuation

  test "terminates (does not hang) when a fence opener alone leaves no room":
    # Regression: a fence-opening line long enough that even a freshly
    # reopened chunk has no room before FenceCloseReserve used to loop
    # forever, reachable at the default maxLen=1900 both real call sites
    # (discord.nim, talos_agent.nim) use.
    let longFence = "```" & "x".repeat(1897)
    let content = longFence & "\n" & "some code\n" & "more code\n" & "```\n"
    let chunks = chunkMessage(content, maxLen = 1900)
    check chunks.len > 0
    for chunk in chunks:
      check chunk.len <= 1900

  test "terminates (does not hang) when maxLen is smaller than the continuation marker":
    # Regression: maxLen <= ContinuationMarker.len used to loop forever
    # for any sufficiently long fragment.
    let chunks = chunkMessage("a".repeat(20), maxLen = 2)
    check chunks.len > 0
    var total = 0
    for chunk in chunks:
      total += chunk.len
    check total > 0
