## Tests for talos_core/token_counter.nim
##
## Verifies:
##   - countTokens returns expected values for known strings
##   - countTokens handles edge cases (empty, single char)
##   - detectFamily classifies model strings correctly
##   - countMessages applies per-message overhead correctly
##   - countMessages handles empty message list

import std/[unittest, strutils]
import talos_core/token_counter
import talos_core/llm_client

# ---------------------------------------------------------------------------
# Suite: detectFamily
# ---------------------------------------------------------------------------

suite "detectFamily":
  test "gpt-4 variants":
    check detectFamily("gpt-4") == mfGpt4
    check detectFamily("gpt-4o") == mfGpt4
    check detectFamily("gpt-4-turbo") == mfGpt4
    check detectFamily("GPT-4") == mfGpt4
    check detectFamily("gpt4o") == mfGpt4

  test "o-series":
    check detectFamily("o1") == mfGpt4
    check detectFamily("o1-mini") == mfGpt4
    check detectFamily("o3") == mfGpt4
    check detectFamily("o4-mini") == mfGpt4

  test "gpt-3.5 variants":
    check detectFamily("gpt-3.5-turbo") == mfGpt35
    check detectFamily("gpt-35-turbo") == mfGpt35
    check detectFamily("gpt3.5") == mfGpt35

  test "claude variants":
    check detectFamily("claude-3-opus") == mfClaude
    check detectFamily("claude-3.5-sonnet") == mfClaude
    check detectFamily("claude-3.7-sonnet") == mfClaude
    check detectFamily("claude-2") == mfClaude
    check detectFamily("claude") == mfClaude

  test "llama / mistral / gemma":
    check detectFamily("llama-3") == mfLlama
    check detectFamily("llama3") == mfLlama
    check detectFamily("meta-llama/llama-3") == mfLlama
    check detectFamily("mistral-7b") == mfLlama
    check detectFamily("gemma-2") == mfLlama
    check detectFamily("mixtral-8x7b") == mfLlama

  test "unknown falls back to default":
    check detectFamily("") == mfDefault
    check detectFamily("some-unknown-model") == mfDefault
    check detectFamily("palm-2") == mfDefault

# ---------------------------------------------------------------------------
# Suite: countTokens edge cases
# ---------------------------------------------------------------------------

suite "countTokens edge cases":
  test "empty string returns 0":
    check countTokens("") == 0
    check countTokens("", "gpt-4") == 0
    check countTokens("", "claude-3") == 0

  test "single character returns 1":
    check countTokens("a") == 1
    check countTokens("a", "gpt-4") == 1
    check countTokens("a", "claude-3") == 1

# ---------------------------------------------------------------------------
# Suite: countTokens known values — GPT-4 (4.0 chars/token)
# ---------------------------------------------------------------------------

suite "countTokens gpt-4":
  test "4-char string = 1 token":
    # "test" = 4 chars / 4.0 = 1.0 → 1
    check countTokens("test", "gpt-4") == 1

  test "8-char string = 2 tokens":
    # "testtest" = 8 chars / 4.0 = 2.0 → 2
    check countTokens("testtest", "gpt-4") == 2

  test "5-char string rounds up to 2 tokens":
    # "hello" = 5 chars / 4.0 = 1.25 → ceil → 2
    check countTokens("hello", "gpt-4") == 2

  test "12-char string = 3 tokens":
    # "Hello, World" = 12 chars / 4.0 = 3.0 → 3
    check countTokens("Hello, World", "gpt-4") == 3

  test "100-char string = 25 tokens":
    let s = "a".repeat(100)
    check countTokens(s, "gpt-4") == 25

# ---------------------------------------------------------------------------
# Suite: countTokens known values — Claude (3.8 chars/token)
# ---------------------------------------------------------------------------

suite "countTokens claude":
  test "3-char string rounds up to 1 token":
    # "abc" = 3 chars / 3.8 = 0.789 → ceil → 1
    check countTokens("abc", "claude-3") == 1

  test "4-char string rounds up to 2 tokens":
    # "abcd" = 4 chars / 3.8 = 1.052 → ceil → 2
    check countTokens("abcd", "claude-3") == 2

  test "38-char string = 10 tokens":
    let s = "a".repeat(38)
    # 38 / 3.8 = 10.0 → 10
    check countTokens(s, "claude-3") == 10

  test "claude-3.5-sonnet uses claude family":
    check countTokens("hello", "claude-3.5-sonnet") ==
          countTokens("hello", "claude-3")

# ---------------------------------------------------------------------------
# Suite: countTokens known values — Llama (4.0 chars/token)
# ---------------------------------------------------------------------------

suite "countTokens llama":
  test "llama uses same ratio as gpt-4":
    let texts = ["The quick brown fox", "Meta Llama 3", "1234567890"]
    for t in texts:
      check countTokens(t, "llama-3") == countTokens(t, "gpt-4")

  test "mistral uses llama family":
    check countTokens("hello", "mistral-7b") == countTokens("hello", "llama-3")

# ---------------------------------------------------------------------------
# Suite: countMessages
# ---------------------------------------------------------------------------

suite "countMessages":
  test "empty sequence returns 0":
    let msgs: seq[ChatMessage] = @[]
    check countMessages(msgs, "gpt-4") == 0

  test "single message: overhead + content tokens":
    # 1 message: ReplyPrimingTokens(3) + TokensPerMessage(4) + content tokens
    let msgs = @[ChatMessage(role: crUser, content: "hello")]
    # "hello" = 5 chars / 4.0 = 1.25 → ceil → 2 tokens
    let expected = ReplyPrimingTokens + TokensPerMessage + countTokens("hello", "gpt-4")
    check countMessages(msgs, "gpt-4") == expected

  test "two messages accumulate correctly":
    let msgs = @[
      ChatMessage(role: crSystem, content: "You are helpful."),
      ChatMessage(role: crUser, content: "Hello!"),
    ]
    var expected = ReplyPrimingTokens
    for m in msgs:
      expected += TokensPerMessage + countTokens(m.content, "gpt-4")
    check countMessages(msgs, "gpt-4") == expected

  test "named participant adds extra tokens":
    let msgs = @[
      ChatMessage(role: crUser, content: "hi", name: "Alice"),
    ]
    # name "Alice" = 5 chars / 4.0 = 2 tokens + 1 extra = 3
    let nameTokens = countTokens("Alice", "gpt-4") + 1
    let expected = ReplyPrimingTokens + TokensPerMessage +
                   countTokens("hi", "gpt-4") + nameTokens
    check countMessages(msgs, "gpt-4") == expected

  test "empty content message still adds overhead":
    let msgs = @[ChatMessage(role: crAssistant, content: "")]
    # content = 0 tokens, but overhead still applies
    let expected = ReplyPrimingTokens + TokensPerMessage + 0
    check countMessages(msgs, "gpt-4") == expected

  test "claude model uses claude ratio for content":
    # Claude has slightly more tokens per char (3.8 vs 4.0), so "hello" (5 chars)
    # gives 2 tokens for both (ceil(5/4.0)=2, ceil(5/3.8)=2), overhead is same.
    # For longer text the difference shows.
    let longMsgs = @[ChatMessage(role: crUser, content: "a".repeat(100))]
    let gptLong = countMessages(longMsgs, "gpt-4")
    let claudeLong = countMessages(longMsgs, "claude-3")
    # 100 chars: gpt=25 tokens, claude=ceil(100/3.8)=27 tokens. Exact values,
    # not just "claude is bigger" — a formula bug that still kept the
    # ordering right (e.g. off by a constant) would slip past a directional
    # check but not this one.
    check gptLong == ReplyPrimingTokens + TokensPerMessage + 25
    check claudeLong == ReplyPrimingTokens + TokensPerMessage + 27
