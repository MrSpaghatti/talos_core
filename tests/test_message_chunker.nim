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
