## Fence-aware Discord message chunking.

import std/strutils

const ContinuationMarker* = "..."
const FenceMarker = "```"
const FenceCloseReserve = 4

proc chunkMessage*(content: string; maxLen = 1900): seq[string] =
  if content.len == 0 or maxLen <= 0:
    return @[]

  proc closeChunk(chunk: string; inFence: bool): string =
    result = chunk
    if inFence:
      if result.len > 0 and result[result.high] != '\n':
        result.add '\n'
      result.add FenceMarker

  proc startChunk(inFence: bool; fenceOpener: string): string =
    if inFence:
      result = fenceOpener & "\n"
    else:
      result = ""

  var chunks: seq[string] = @[]
  var current = ""
  var inFence = false
  var fenceOpener = ""

  proc flushCurrent() =
    if current.len == 0:
      return
    chunks.add closeChunk(current, inFence)
    current = startChunk(inFence, fenceOpener)

  proc roomLeft(): int =
    result = maxLen - current.len
    if inFence:
      result -= FenceCloseReserve

  proc appendFragment(fragment: string) =
    var remaining = fragment
    while remaining.len > 0:
      var room = roomLeft()
      if room <= 0:
        flushCurrent()
        continue

      if remaining.len <= room:
        current.add remaining
        remaining.setLen(0)
      else:
        if room <= ContinuationMarker.len:
          flushCurrent()
          continue
        let take = room - ContinuationMarker.len
        current.add remaining[0 ..< take]
        current.add ContinuationMarker
        remaining = remaining[take .. ^1]
        flushCurrent()

  var i = 0
  while i < content.len:
    let lineStart = i
    while i < content.len and content[i] != '\n':
      inc i
    var line = content[lineStart ..< i]
    if i < content.len and content[i] == '\n':
      line.add '\n'
      inc i

    if line.startsWith(FenceMarker):
      appendFragment(line)
      if not inFence:
        inFence = true
        fenceOpener = line.strip(trailing = true, chars = {'\r', '\n'})
      else:
        inFence = false
        fenceOpener = ""
      continue

    appendFragment(line)

  if current.len > 0:
    chunks.add closeChunk(current, inFence)

  result = chunks
