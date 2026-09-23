# AGENTS.md — rules for any AI coding agent working in this repo

Read this file fully before every task. Then read the docs the task names.

## Project
IELTS Writing Task 2 scorer. React frontend, Go/Gin backend, Python scoring worker,
Redis queue, Postgres + pgvector. Spec: `docs/OVERVIEW.md`. Scoring rules:
`docs/SCORING_RULES.md`. Feature definitions: `docs/FEATURES.md`. In-app LLM prompts:
`docs/LLM_PROMPTS.md`.

## Repo layout
```
frontend/        React (Vite)
backend/         Go + Gin; the ONLY service that reads/writes Postgres
worker/          Python 3.11+
  scoring/       LLM calls, schemas, band math
  features/      deterministic NLP features (no LLM calls in here, ever)
  checklist/     narrow LLM judgment questions
  tests/         pytest; fixtures in tests/fixtures/
eval/            eval scripts + results; writes EVAL.md
rubric/          official descriptor text (fetched, never paraphrased)
docker-compose.yml   postgres (pgvector), redis, languagetool
```

## Hard rules
1. **One task at a time.** Do only what the current task asks. If you see something else
   worth doing, list it at the end under "Follow-ups". Don't do it.
2. **Never invent numbers.** No band thresholds, no "rare = under 2%" cut-offs, no
   descriptor wording from memory. If a task needs a threshold that isn't in the docs, stop
   and ask.
3. **`features/` is deterministic.** Same input → same output. No LLM calls, no network
   except the local LanguageTool container.
4. **Band math lives in code** (`scoring/bands.py`), as defined in `docs/SCORING_RULES.md`.
   The LLM never computes overall bands.
5. **LLM provider is swappable.** Use the `openai` Python client with `base_url`,
   `api_key` and `model` from `.env`. No provider-specific SDKs. Temperature comes from
   config (default 0).
6. **Every LLM response is validated with pydantic.** On a validation failure, allow one
   repair attempt with the validation error included, then raise.
7. **Tests prove each task.** Every task ends with `pytest` passing, and the relevant
   command's real output pasted in your final message. Don't claim something works without
   running it.
8. **Don't change tests to make them pass.** If a fixture's expected value looks wrong,
   say so and stop.
9. **Don't touch files in `docs/`** unless the task says to.

## Definition of done (every task)
- Code + tests written, `pytest -q` passes, output shown
- New config keys added to `.env.example`
- A short summary: files changed, what was verified, anything uncertain, follow-ups
