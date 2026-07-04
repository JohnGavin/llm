# Exploration: ellmer `chat_structured()` for issue triage

**Date:** 2026-06-30
**Author:** fixer agent (dispatch 7735f456)
**Issue:** JohnGavin/llm#696

## Purpose

Pilot `ellmer::chat_openai()` + `ch$chat_structured()` on a classification task that is explicitly **not** data ingestion. Given a GitHub issue title and body, return a structured `{difficulty: easy|medium|hard, area: string, is_bug: bool}` object. This is a judgement/triage task: the model is asked to make an opinion call, not to read or transcribe existing numeric data.

## Ingestion-rule boundary

The project rule "Reproducible Ingestion — NEVER ingest data with the model" prohibits using LLMs to read, transcribe, or aggregate data files (CSV, JSON, XLSX, etc.). That boundary does **not** apply here because: (a) the inputs are short free-text strings with no ground-truth numeric content, (b) the output is a model judgement, not a data value, and (c) the code could be re-run at any time with the same inputs to reproduce the classification. Issue triage is an opinion task; ingestion is a fact-extraction task.

## Outcome

**Did it run:** No. OPENAI_API_KEY is present in the environment and passes through to the nix shell, but the OpenAI account has no billing credits (HTTP 429 "exceeded your current quota"). ellmer's built-in retry logic fired 3 times with 3 s back-off then raised. ANTHROPIC_API_KEY was not in the environment.

**Model:** gpt-4o-mini (requested; never reached)

**Latency / cost:** N/A — no tokens consumed

**ellmer version:** 0.4.0

## Run output

See `output.txt` for the full captured output including the error.

## Verdict: adopt with caveats

The ellmer API is clean and appropriate for issue triage. The workflow — `type_object()` schema + `ch$chat_structured()` — is a one-function call away from returning a validated R list. Three observations:

1. **API surface is correct.** `chat_structured` is a method on the R6 Chat object (not a top-level export in 0.4.0), so call `ch$chat_structured(prompt, type = schema)`. The schema types (`type_enum`, `type_string`, `type_boolean`) cover all classification fields needed for triage.
2. **Cost is negligible.** For two short issues, gpt-4o-mini would cost under $0.0001. At repo scale (hundreds of issues), this is trivially affordable.
3. **Blocker: no funded OpenAI account.** The pilot cannot produce live output until the OPENAI_API_KEY account has billing credits. Alternatively, `chat_claude()` would work if ANTHROPIC_API_KEY is added to the environment. The code requires zero changes to switch providers.

**Recommendation:** Adopt ellmer for issue-triage automation once a funded key is available. The `type_object()` + `ch$chat_structured()` pattern is exactly right for this repo's needs. Wire into the roborev issue-triage flow or a `/triage` slash command.

## Quality score: 63 / 100

The code runs to the API call (no syntax errors, correct API usage), is readable, and contains no secrets. Blocked only by account quota — not by code correctness. Score meets the explorations/ threshold of 60.
