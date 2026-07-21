## Talos token counter — approximation-based BPE wrapper.
##
## Provides token count estimates for common LLM model families without
## requiring external vocabulary files or native BPE libraries.
##
## Approach:
##   - GPT-4 / GPT-3.5 / o-series: ~4 chars per token (cl100k_base / o200k_base)
##   - Claude (all versions):       ~3.8 chars per token (Anthropic calibration)
##   - Llama / Mistral / Gemma:     ~4 chars per token (SentencePiece BPE)
##   - Unknown models:              ~4 chars per token (conservative default)
##
## Per-message overhead (role + formatting tokens) follows OpenAI's documented
## formula: 4 tokens per message + 1 token for reply priming.
##
## References:
##   - https://platform.openai.com/docs/guides/chat/managing-tokens
##   - Anthropic token estimation guidance (~3.8 chars/token)
##
## Out of scope (deferred):
##   - Exact BPE tokenization (requires vocabulary files)
##   - Streaming token counting
##   - Tool call token overhead

import std/[strutils, math]
import talos_core/llm_client

# ---------------------------------------------------------------------------
# Model family detection
# ---------------------------------------------------------------------------

type
  ModelFamily* = enum
    ## Broad tokenizer family used for approximation.
    mfGpt4       ## GPT-4, GPT-4o, o1, o3, o4 — o200k_base / cl100k_base
    mfGpt35      ## GPT-3.5-turbo — cl100k_base
    mfClaude     ## Claude 1/2/3/3.5/3.7 — Anthropic BPE
    mfLlama      ## Llama 1/2/3, Mistral, Gemma — SentencePiece BPE
    mfDefault    ## Unknown / fallback

const
  ## Characters per token for each model family.
  CharsPerToken: array[ModelFamily, float] = [
    4.0,   # mfGpt4
    4.0,   # mfGpt35
    3.8,   # mfClaude
    4.0,   # mfLlama
    4.0,   # mfDefault
  ]

  ## Extra tokens added per message (role label + formatting).
  ## OpenAI formula: 4 tokens per message.
  TokensPerMessage* = 4

  ## Tokens added for reply priming at the end of a message list.
  ReplyPrimingTokens* = 3

proc detectFamily*(model: string): ModelFamily =
  ## Classifies a model string into a broad tokenizer family.
  ## Case-insensitive prefix/substring matching.
  let m = model.toLowerAscii()
  if m.startsWith("gpt-4") or m.startsWith("gpt4") or
     m.startsWith("o1") or m.startsWith("o3") or m.startsWith("o4") or
     m.contains("gpt-4o") or m.contains("gpt4o"):
    return mfGpt4
  if m.startsWith("gpt-3.5") or m.startsWith("gpt3.5") or
     m.startsWith("gpt-35"):
    return mfGpt35
  if m.startsWith("claude"):
    return mfClaude
  if m.startsWith("llama") or m.startsWith("mistral") or
     m.startsWith("gemma") or m.startsWith("mixtral") or
     m.startsWith("meta-llama"):
    return mfLlama
  mfDefault

# ---------------------------------------------------------------------------
# Core counting
# ---------------------------------------------------------------------------

proc countTokens*(text: string; model: string = "gpt-4"): int =
  ## Returns an estimated token count for `text` given `model`.
  ##
  ## Uses character-ratio approximation calibrated per model family.
  ## Empty strings return 0.
  if text.len == 0:
    return 0
  let family = detectFamily(model)
  let ratio = CharsPerToken[family]
  # Round up: partial tokens still consume a full token slot.
  result = int(ceil(text.len.float / ratio))
  if result < 1:
    result = 1

proc countMessages*(messages: seq[ChatMessage]; model: string = "gpt-4"): int =
  ## Returns an estimated total token count for a sequence of chat messages.
  ##
  ## Applies per-message overhead (role + formatting) on top of content tokens,
  ## following OpenAI's documented formula.  The same overhead is used for all
  ## model families as a reasonable approximation.
  ##
  ## Formula:
  ##   sum over messages of:
  ##     TokensPerMessage + countTokens(content) + countTokens(name)
  ##   + ReplyPrimingTokens
  if messages.len == 0:
    return 0
  result = ReplyPrimingTokens
  for msg in messages:
    result += TokensPerMessage
    result += countTokens(msg.content, model)
    if msg.name.len > 0:
      # Named participants add 1 extra token (the name itself is counted above).
      result += countTokens(msg.name, model) + 1
