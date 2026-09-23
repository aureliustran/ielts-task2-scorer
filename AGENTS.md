# AGENTS.md — rules for any AI coding agent working in this repo

Read this file fully before every task. Then read the docs the task names.

## Project
IELTS Writing Task 2 scorer. React client, Go/Gin server, Python scoring worker, Redis
queue, Postgres + pgvector.

| Doc | Contains |
|---|---|
| `docs/SPEC.md` | Goal, services, config, Redis contracts, DB schema, HTTP API, client |
| `docs/SCORING.md` | Scoring pipeline, pre-checks, features, prompts (verbatim), band math, schemas, LLM client |
| `docs/EVALUATION.md` | Eval set, splits, metrics, cost controls, eval outputs |
| `docs/TASKS.md` | Build order and the task prompts |

## Repo layout
```
client/          React (Vite)
server/          Go + Gin; the ONLY service that reads/writes Postgres
worker/          Python 3.11+; no Postgres access
  main.py        Redis queue loop
  embedding.py   local sentence embeddings
  scoring/       LLM client, schemas, band math, pipeline, CLI
  features/      deterministic NLP features (no LLM calls in here, ever)
  checklist/     narrow LLM judgment questions
  prompts/       versioned prompt files ({name}.v{N}.txt)
  tests/         pytest; fixtures in tests/fixtures/
evaluator/       offline eval; imports worker's pipeline; data/, results/
rubric/          official descriptor text (fetched, never paraphrased)
docker-compose.yml   postgres (pgvector), redis, languagetool
```

Each service has its own git-ignored `.env`. `docs/SPEC.md` §4 says what goes where.

## Hard rules
1. **One task at a time.** Do only what the current task asks. If you see something else
   worth doing, list it at the end under "Follow-ups". Don't do it.
2. **Never invent numbers.** No band thresholds, no "rare = under 2%" cut-offs, no
   descriptor wording from memory. If a task needs a threshold that isn't in the docs, stop
   and ask.
3. **`features/` is deterministic.** Same input → same output. No LLM calls, no network
   except the local LanguageTool container.
4. **Band math lives in code** (`scoring/bands.py`), as defined in `docs/SCORING.md` §7.
   The LLM never computes overall bands.
5. **LLM provider is swappable.** Use the `openai` Python client with `base_url`,
   `api_key` and `model` from `.env`. No provider-specific SDKs. Temperature comes from
   config (default 0).
6. **Every LLM response is validated with pydantic.** On a validation failure, allow one
   repair attempt with the validation error included, then raise.
7. **Prompts are copied verbatim** from `docs/SCORING.md` §6. A prompt file used in an eval
   run is never edited again; create the next version instead.
8. **The eval set is not training data.** Nothing is trained. Graded essays are only for
   measuring (`docs/EVALUATION.md` §1). Never hand-mark an essay or invent a band for one.
9. **Tests prove each task.** Every task ends with its tests passing (`pytest -q`,
   `go test ./...`, or `npm run build` + `npm run lint`) and the real output pasted in your
   final message. Don't claim something works without running it.
10. **Don't change tests to make them pass.** If an expected value looks wrong, say so and
    stop.
11. **Don't touch files in `docs/`** unless the task says to.

## Definition of done (every task)
- Code + tests written, tests pass, output shown
- New config keys added to the service's `.env.example`
- A short summary: files changed, what was verified, anything uncertain, follow-ups
