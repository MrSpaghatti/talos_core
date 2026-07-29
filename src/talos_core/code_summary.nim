## Structural source-code summarization (task-18).
##
## `summarizeSource` turns a source file into a structural summary —
## top-level signatures and their immediately-attached doc comments, with
## implementation bodies elided — instead of the full raw text. Used by
## `file_tool.fileReadTool` to avoid spending full-file tokens on every
## read once a file crosses a size threshold; a full-content read stays
## available via that tool's `full` parameter.
##
## This is a lightweight per-language heuristic parser, not a real
## grammar (no tree-sitter binding — see task-18's own framing: an FFI
## investigation for a marginal correctness gain isn't worth it for the
## ~4-5 languages Talos's own codebase actually uses, mirroring the
## brute-force-over-sqlite-vec call from Task 5). Two families of
## languages, two scanning strategies:
##
## - Indentation-based (Nim, Python): a signature line's body is
##   "whatever follows at strictly greater indentation," elided down to a
##   single placeholder, except for a doc-comment/docstring immediately
##   after the signature, which is always kept in full.
## - Brace-based (Rust, C, C++): a signature line's body is the span
##   between its `{` and the matching `}` (tracked by depth, not a real
##   tokenizer). The scan recurses into that span looking for *further*
##   nested signatures (e.g. a Rust `impl` block's individual `fn`s, a
##   C++ `class`'s methods) so containers don't just vanish into one
##   opaque placeholder — only genuine leaf bodies get elided.
##
## Known limitations (heuristic, not a parser): multi-line signatures
## (params spanning several lines before `=` or `{`) are only recognized
## from their first line — anything else on the continuation lines is
## swallowed into the elided body rather than kept as part of the header.
## Brace/quote/indent detection doesn't understand string or comment
## literals containing stray `{`/`}` characters. Good enough for a
## heuristic summary; not a substitute for a real parse.

import std/[os, strutils]

type
  SourceLang* = enum
    slNim
    slPython
    slRust
    slC
    slCpp
    slUnknown

const
  DefaultSummarizeThresholdLines* = 200
    ## Files at or below this many lines are returned in full — no point
    ## summarizing something already small.

proc detectLang*(path: string): SourceLang =
  case path.splitFile().ext.toLowerAscii()
  of ".nim", ".nims": slNim
  of ".py": slPython
  of ".rs": slRust
  of ".c", ".h": slC
  of ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx": slCpp
  else: slUnknown

proc leadingIndent(line: string): int =
  line.len - line.strip(leading = true, trailing = false).len

proc startsWithAny(s: string; prefixes: openArray[string]): bool =
  for p in prefixes:
    if s.startsWith(p):
      return true
  false

# ---------------------------------------------------------------------------
# Indentation-based summarizer (Nim, Python)
# ---------------------------------------------------------------------------

type
  DocCaptureProc = proc(lines: seq[string]; startIdx: int): int {.closure.}
    ## Given the body's first line index, returns how many lines from
    ## there should be kept verbatim as an attached doc comment/docstring
    ## (0 if the body doesn't start with one).

proc summarizeIndentedRegion(
    lines: seq[string]; startIdx, endIdxExcl: int;
    isSignatureStart: proc(stripped: string): bool {.closure.};
    captureDoc: DocCaptureProc;
    headerTerminator: string;
    output: var seq[string];
    elideNonSignatureContent: bool;
) =
  ## `headerTerminator`: the trailing token that marks a signature line as
  ## *complete* ("=" for Nim, opening a proc body; ":" for Python, opening
  ## a def/class suite). A signature line not already ending in this is
  ## treated as the first line of a multi-line signature (params spanning
  ## several lines, common in this very codebase) — continuation lines
  ## are kept verbatim in the header rather than folded into the elided
  ## body, up to `headerContinuationGuard` lines as a runaway safety cap.
  ##
  ## A signature's body is recursed into (not blindly elided) so a
  ## Python `class`'s nested `def`s — or a Nim closure/inner proc — still
  ## get their own header-kept/body-elided treatment rather than
  ## vanishing into one opaque placeholder along with the rest of the
  ## container.
  ##
  ## `elideNonSignatureContent`: false at true module/file top level —
  ## imports, consts, and (for Nim) `type` blocks are structure, not
  ## implementation, and are kept verbatim there. true when recursing
  ## into a signature's own body, where non-signature content genuinely
  ## is implementation (statements, control flow) and gets collapsed to
  ## one in-place placeholder per consecutive run.
  const headerContinuationGuard = 40
  var i = startIdx
  while i < endIdxExcl:
    let line = lines[i]
    let stripped = line.strip()

    if stripped.len == 0:
      inc i
      continue

    if isSignatureStart(stripped):
      output.add(line)
      let baseIndent = leadingIndent(line)
      inc i

      if not stripped.endsWith(headerTerminator):
        var guard = 0
        while i < endIdxExcl and guard < headerContinuationGuard:
          if lines[i].strip().len == 0:
            # A blank line before the header ever terminates most likely
            # means this was a bodyless forward declaration, not a
            # continuation — stop rather than risk consuming unrelated
            # code that follows.
            break
          output.add(lines[i])
          let contComplete = lines[i].strip().endsWith(headerTerminator)
          inc i
          inc guard
          if contComplete:
            break

      # Keep a doc comment/docstring immediately attached to this signature.
      let docLines = captureDoc(lines, i)
      for k in 0 ..< docLines:
        output.add(lines[i])
        inc i

      # Find the body's extent: everything more-indented than baseIndent,
      # tolerating blank lines within it (a blank line only ends the body
      # if what follows it has dedented back to baseIndent or less).
      var bodyEnd = i
      while bodyEnd < endIdxExcl:
        if lines[bodyEnd].strip().len == 0:
          var j = bodyEnd
          while j < endIdxExcl and lines[j].strip().len == 0:
            inc j
          if j >= endIdxExcl or leadingIndent(lines[j]) <= baseIndent:
            break
          bodyEnd = j
          continue
        if leadingIndent(lines[bodyEnd]) > baseIndent:
          inc bodyEnd
        else:
          break

      if bodyEnd > i:
        var inner: seq[string] = @[]
        summarizeIndentedRegion(lines, i, bodyEnd, isSignatureStart, captureDoc,
          headerTerminator, inner, elideNonSignatureContent = true)
        output.add(inner)
      i = bodyEnd
      continue

    if not elideNonSignatureContent:
      # Top-level structure (imports, consts, Nim `type` blocks, ...) —
      # not implementation, kept verbatim.
      output.add(line)
      inc i
      continue

    # Non-signature content inside a signature's body (plain statements, a
    # nested if/for, decorators, etc.): consume the whole consecutive run
    # — its own internal indentation doesn't matter here, none of it is a
    # signature in this region — and emit exactly one placeholder for the
    # run, in place.
    let runIndent = leadingIndent(line)
    var consumedAny = false
    while i < endIdxExcl:
      if lines[i].strip().len == 0:
        inc i
        continue
      if isSignatureStart(lines[i].strip()):
        break
      consumedAny = true
      inc i
    if consumedAny:
      output.add(" ".repeat(runIndent) & "...")

proc summarizeIndented(
    content: string;
    isSignatureStart: proc(stripped: string): bool {.closure.};
    captureDoc: DocCaptureProc;
    headerTerminator: string;
): string =
  let lines = content.splitLines()
  var output: seq[string] = @[]
  summarizeIndentedRegion(lines, 0, lines.len, isSignatureStart, captureDoc,
    headerTerminator, output, elideNonSignatureContent = false)
  output.join("\n")

proc nimDocCapture(lines: seq[string]; startIdx: int): int =
  result = 0
  var i = startIdx
  while i < lines.len and lines[i].strip().startsWith("##"):
    inc result
    inc i

proc pythonDocCapture(lines: seq[string]; startIdx: int): int =
  if startIdx >= lines.len:
    return 0
  let first = lines[startIdx].strip()
  for delim in ["\"\"\"", "'''"]:
    if first.startsWith(delim):
      let rest = first[delim.len .. ^1]
      if rest.endsWith(delim) and rest.len >= delim.len:
        return 1  # one-line docstring: """Does X."""
      var i = startIdx + 1
      while i < lines.len:
        if lines[i].contains(delim):
          return i - startIdx + 1
        inc i
      return lines.len - startIdx  # unterminated — keep to EOF rather than guess
  return 0

proc summarizeNim(content: string): string =
  const sigPrefixes = [
    "proc ", "proc*", "func ", "func*", "method ", "method*",
    "template ", "template*", "macro ", "macro*", "iterator ", "iterator*",
    "converter ", "converter*",
  ]
  summarizeIndented(
    content,
    proc(s: string): bool = startsWithAny(s, sigPrefixes),
    nimDocCapture,
    headerTerminator = "=",
  )

proc summarizePython(content: string): string =
  summarizeIndented(
    content,
    proc(s: string): bool = startsWithAny(s, ["def ", "async def ", "class "]),
    pythonDocCapture,
    headerTerminator = ":",
  )

# ---------------------------------------------------------------------------
# Brace-based summarizer (Rust, C, C++)
# ---------------------------------------------------------------------------

proc braceDelta(line: string): int =
  for ch in line:
    if ch == '{': inc result
    elif ch == '}': dec result

proc summarizeBraceRegion(
    lines: seq[string]; startIdx, endIdxExcl: int;
    isSignatureStart: proc(stripped: string): bool {.closure.};
    isDataContainerStart: proc(stripped: string): bool {.closure.};
    isDocComment: proc(stripped: string): bool {.closure.};
    output: var seq[string];
    elideNonSignatureContent: bool;
) =
  ## `isDataContainerStart` matches pure-data containers (struct/enum/union
  ## in C/Rust — never methods, unlike a C++ class or a Rust impl block):
  ## their bodies are field lists, which are structure, not
  ## implementation, so they're kept in full rather than elided — the
  ## same treatment `summarizeIndented` gives a Nim `type` block.
  ##
  ## `elideNonSignatureContent`: false at true file top level — `use`/
  ## `#include`/other top-level declarations are structure, kept verbatim
  ## there. true when recursing into a signature's own `{...}` body,
  ## where non-signature content genuinely is implementation.
  var i = startIdx
  while i < endIdxExcl:
    let line = lines[i]
    let stripped = line.strip()

    if stripped.len == 0:
      inc i
      continue

    if isDocComment(stripped):
      output.add(line)
      inc i
      continue

    if isDataContainerStart(stripped):
      output.add(line)
      var depth = braceDelta(line)
      inc i
      if depth <= 0:
        continue
      while i < endIdxExcl and depth > 0:
        output.add(lines[i])
        depth += braceDelta(lines[i])
        inc i
      continue

    if isSignatureStart(stripped):
      output.add(line)
      var depth = braceDelta(line)
      if depth <= 0:
        # A declaration with no body on this line (forward decl, or a
        # multi-line signature whose `{` hasn't appeared yet — see the
        # module docstring's multi-line limitation).
        inc i
        continue
      let bodyStart = i + 1
      var j = bodyStart
      while j < endIdxExcl and depth > 0:
        depth += braceDelta(lines[j])
        if depth == 0:
          break
        inc j
      var inner: seq[string] = @[]
      summarizeBraceRegion(lines, bodyStart, j, isSignatureStart, isDataContainerStart,
        isDocComment, inner, elideNonSignatureContent = true)
      output.add(inner)
      if j < endIdxExcl:
        output.add(lines[j])
        i = j + 1
      else:
        i = j
      continue

    if not elideNonSignatureContent:
      # Top-level structure (use/#include/other declarations) — not
      # implementation, kept verbatim.
      output.add(line)
      inc i
      continue

    # Non-signature content inside a signature's body (a stray statement,
    # etc.): skip each such line's own brace-delimited block wholesale,
    # and emit exactly one placeholder for the whole consecutive run, in
    # place — not deferred to the end of the enclosing region, so it
    # stays next to whatever it actually replaced.
    var consumedAny = false
    while i < endIdxExcl:
      let s2 = lines[i].strip()
      if s2.len == 0:
        inc i
        continue
      if isDocComment(s2) or isSignatureStart(s2) or isDataContainerStart(s2):
        break
      var depth = braceDelta(lines[i])
      inc i
      consumedAny = true
      while depth > 0 and i < endIdxExcl:
        depth += braceDelta(lines[i])
        inc i
    if consumedAny:
      output.add("    ...")

proc summarizeBraced(
    content: string;
    isSignatureStart: proc(stripped: string): bool {.closure.};
    isDataContainerStart: proc(stripped: string): bool {.closure.};
    isDocComment: proc(stripped: string): bool {.closure.};
): string =
  let lines = content.splitLines()
  var output: seq[string] = @[]
  summarizeBraceRegion(lines, 0, lines.len, isSignatureStart, isDataContainerStart,
    isDocComment, output, elideNonSignatureContent = false)
  output.join("\n")

proc summarizeRust(content: string): string =
  const behaviorPrefixes = [
    "fn ", "pub fn ", "pub(crate) fn ", "async fn ", "pub async fn ",
    "unsafe fn ", "pub unsafe fn ",
    "trait ", "pub trait ", "impl ", "mod ", "pub mod ",
  ]
  const dataPrefixes = ["struct ", "pub struct ", "enum ", "pub enum "]
  summarizeBraced(
    content,
    proc(s: string): bool = startsWithAny(s, behaviorPrefixes),
    proc(s: string): bool = startsWithAny(s, dataPrefixes),
    proc(s: string): bool = s.startsWith("///") or s.startsWith("//!"),
  )

proc looksLikeCFunctionSignature(s: string): bool =
  if s.startsWith("#") or s.startsWith("//") or s.startsWith("*"):
    return false
  if startsWithAny(s, ["class ", "namespace "]):
    return s.contains("{")
  # A function definition: has a parameter list and its brace opens on
  # this same line (see module docstring's multi-line limitation).
  s.contains("(") and s.contains(")") and s.endsWith("{")

proc looksLikeCDataContainer(s: string): bool =
  startsWithAny(s, ["struct ", "enum ", "union "]) and s.contains("{")

proc summarizeC(content: string): string =
  summarizeBraced(
    content,
    looksLikeCFunctionSignature,
    looksLikeCDataContainer,
    proc(s: string): bool = s.startsWith("///") or s.startsWith("//!") or
      s.startsWith("/*") or s.startsWith("* ") or s == "*/",
  )

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc summarizeSource*(content: string; lang: SourceLang): string =
  ## Returns a structural summary of `content` for a recognized `lang`
  ## (signatures/doc comments kept, bodies elided). Unrecognized languages
  ## (`slUnknown`) are returned unchanged — summarizing a format this
  ## module doesn't understand risks garbling it for no benefit.
  case lang
  of slNim: summarizeNim(content)
  of slPython: summarizePython(content)
  of slRust: summarizeRust(content)
  of slC, slCpp: summarizeC(content)
  of slUnknown: content

proc lineCount*(content: string): int =
  content.splitLines().len
