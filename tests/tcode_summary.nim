## Tests for talos_core/code_summary.nim (task-18).

import std/[strutils, unittest]
import talos_core/code_summary

# ---------------------------------------------------------------------------
# Suite: detectLang
# ---------------------------------------------------------------------------

suite "detectLang":
  test "recognizes each supported extension":
    check detectLang("foo.nim") == slNim
    check detectLang("foo.py") == slPython
    check detectLang("foo.rs") == slRust
    check detectLang("foo.c") == slC
    check detectLang("foo.h") == slC
    check detectLang("foo.cpp") == slCpp
    check detectLang("foo.hpp") == slCpp

  test "unrecognized extension is slUnknown":
    check detectLang("foo.txt") == slUnknown
    check detectLang("foo") == slUnknown

  test "is case-insensitive":
    check detectLang("FOO.NIM") == slNim

# ---------------------------------------------------------------------------
# Suite: summarizeSource — slUnknown passthrough
# ---------------------------------------------------------------------------

suite "summarizeSource: unknown language":
  test "returns content unchanged":
    let content = "whatever\nformat\nthis is"
    check summarizeSource(content, slUnknown) == content

# ---------------------------------------------------------------------------
# Suite: summarizeSource — Nim
# ---------------------------------------------------------------------------

const NimSample = """
import std/os

## Module doc.

type
  Foo* = object
    x: int

proc small*(): int =
  42

proc big*(x: int): int =
  ## Doc comment for big.
  var y = x
  for i in 0 ..< 10:
    y += i
  return y

proc multiLine*(
    a: int;
    b: int;
): int =
  a + b

proc noBody*(x: int): int
"""

suite "summarizeSource: Nim":
  test "keeps proc signatures":
    let s = summarizeSource(NimSample, slNim)
    check s.contains("proc small*(): int =")
    check s.contains("proc big*(x: int): int =")
    check s.contains("proc multiLine*(")

  test "elides a proc body, replacing it with a placeholder":
    let s = summarizeSource(NimSample, slNim)
    check not s.contains("y += i")
    check s.contains("...")

  test "keeps a doc comment attached to its proc":
    let s = summarizeSource(NimSample, slNim)
    check s.contains("## Doc comment for big.")

  test "a trivial one-line body is still elided":
    let s = summarizeSource(NimSample, slNim)
    check not s.contains("return y")

  test "a multi-line signature's continuation lines are kept in the header":
    let s = summarizeSource(NimSample, slNim)
    check s.contains("a: int;")
    check s.contains("b: int;")
    check not s.contains("a + b")

  test "a bodyless forward declaration produces no placeholder for it":
    let s = summarizeSource(NimSample, slNim)
    check s.contains("proc noBody*(x: int): int")

  test "the type block is preserved in full, not elided":
    let s = summarizeSource(NimSample, slNim)
    check s.contains("Foo* = object")
    check s.contains("x: int")

  test "the module doc comment (not attached to any proc) is preserved":
    let s = summarizeSource(NimSample, slNim)
    check s.contains("## Module doc.")

  test "is meaningfully smaller than the original":
    let s = summarizeSource(NimSample, slNim)
    check lineCount(s) < lineCount(NimSample)

# ---------------------------------------------------------------------------
# Suite: summarizeSource — Python
# ---------------------------------------------------------------------------

const PySample = "import os\n" &
  "\n" &
  "\n" &
  "def helper(x, y):\n" &
  "    return x + y\n" &
  "\n" &
  "\n" &
  "class Foo:\n" &
  "    \"\"\"A simple class.\"\"\"\n" &
  "\n" &
  "    def __init__(self, x):\n" &
  "        self.x = x\n" &
  "\n" &
  "    def bar(\n" &
  "        self,\n" &
  "        y,\n" &
  "    ):\n" &
  "        \"\"\"Adds y to x.\"\"\"\n" &
  "        result = self.x + y\n" &
  "        return result\n" &
  "\n" &
  "\n" &
  "def one_liner():\n" &
  "    \"\"\"Just a one-liner.\"\"\"\n" &
  "    return 42\n"

suite "summarizeSource: Python":
  test "keeps def/class signatures":
    let s = summarizeSource(PySample, slPython)
    check s.contains("def helper(x, y):")
    check s.contains("class Foo:")
    check s.contains("def one_liner():")

  test "elides function bodies":
    let s = summarizeSource(PySample, slPython)
    check not s.contains("return x + y")
    check not s.contains("return 42")

  test "keeps a docstring attached to its def/class":
    let s = summarizeSource(PySample, slPython)
    check s.contains("\"\"\"A simple class.\"\"\"")
    check s.contains("\"\"\"Just a one-liner.\"\"\"")

  test "recurses into a class body: nested defs get their own header-kept treatment":
    let s = summarizeSource(PySample, slPython)
    check s.contains("def __init__(self, x):")
    check s.contains("def bar(")
    check not s.contains("self.x = x")

  test "a multi-line def's continuation lines are kept in the header, docstring after it is kept":
    let s = summarizeSource(PySample, slPython)
    check s.contains("self,")
    check s.contains("y,")
    check s.contains("\"\"\"Adds y to x.\"\"\"")
    check not s.contains("result = self.x + y")

# ---------------------------------------------------------------------------
# Suite: summarizeSource — Rust
# ---------------------------------------------------------------------------

const RustSample = """
use std::collections::HashMap;

/// A trivial cache.
pub struct Cache {
    data: HashMap<String, String>,
}

impl Cache {
    /// Creates a new empty cache.
    pub fn new() -> Self {
        Cache { data: HashMap::new() }
    }

    pub fn get(&self, key: &str) -> Option<&String> {
        self.data.get(key)
    }
}

fn free_fn(x: i32) -> i32 {
    x + 1
}
"""

suite "summarizeSource: Rust":
  test "keeps struct/impl/fn signatures":
    let s = summarizeSource(RustSample, slRust)
    check s.contains("pub struct Cache {")
    check s.contains("impl Cache {")
    check s.contains("pub fn new() -> Self {")
    check s.contains("fn free_fn(x: i32) -> i32 {")

  test "a struct's fields are kept in full, not elided (data, not implementation)":
    let s = summarizeSource(RustSample, slRust)
    check s.contains("data: HashMap<String, String>,")

  test "elides function bodies inside an impl block":
    let s = summarizeSource(RustSample, slRust)
    check not s.contains("HashMap::new()")
    check not s.contains("self.data.get(key)")
    check s.contains("...")

  test "recurses into impl: each method keeps its own header, elided separately":
    let s = summarizeSource(RustSample, slRust)
    check s.contains("pub fn new() -> Self {")
    check s.contains("pub fn get(&self, key: &str) -> Option<&String> {")

  test "keeps doc comments attached to their item":
    let s = summarizeSource(RustSample, slRust)
    check s.contains("/// A trivial cache.")
    check s.contains("/// Creates a new empty cache.")

  test "a top-level use statement is kept verbatim (structure, not implementation)":
    let s = summarizeSource(RustSample, slRust)
    let lines = s.splitLines()
    check s.contains("use std::collections::HashMap;")
    check lines[0].strip() == "use std::collections::HashMap;"

# ---------------------------------------------------------------------------
# Suite: summarizeSource — C
# ---------------------------------------------------------------------------

const CSample = """
#include <stdio.h>

/* Adds two numbers. */
int add(int a, int b) {
    int result = a + b;
    return result;
}

struct Point {
    int x;
    int y;
};

int main(void) {
    printf("%d\n", add(1, 2));
    return 0;
}
"""

suite "summarizeSource: C":
  test "keeps function and struct signatures":
    let s = summarizeSource(CSample, slC)
    check s.contains("int add(int a, int b) {")
    check s.contains("struct Point {")
    check s.contains("int main(void) {")

  test "elides function bodies":
    let s = summarizeSource(CSample, slC)
    check not s.contains("int result = a + b;")
    check not s.contains("printf")

  test "keeps struct fields in full":
    let s = summarizeSource(CSample, slC)
    check s.contains("int x;")
    check s.contains("int y;")

  test "keeps a doc comment attached to its function":
    let s = summarizeSource(CSample, slC)
    check s.contains("/* Adds two numbers. */")

# ---------------------------------------------------------------------------
# Suite: lineCount
# ---------------------------------------------------------------------------

suite "lineCount":
  test "counts lines":
    check lineCount("a\nb\nc") == 3

  test "empty string has one (empty) line":
    check lineCount("") == 1
