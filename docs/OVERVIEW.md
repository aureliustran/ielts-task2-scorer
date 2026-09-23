# IELTS Writing Task 2 Scorer — Project Spec

## Goal

Build a web app that scores an IELTS Writing Task 2 essay against the official band
descriptors, returning a structured score per criterion plus specific, quoted feedback.

## Purpose

The developer (Aurelius) is a backend engineer (Go/Node.js) transitioning toward AI
engineering skills as part of a longer-term career move toward CTO/co-founder-track roles.
This project is a deliberate, hands-on way to close specific gaps: prompt engineering,
structured LLM output, retrieval/embeddings, and — most importantly — building a real eval
methodology rather than trusting a model's first output at face value. It also doubles as a
portfolio piece: an IELTS band 7-8 holder building a tool that scores against the same
rubric he was scored on is a more credible, differentiated story than a generic demo, and
the polyglot service boundary (Go backend, Python LLM worker) is intentional practice for
directing a multi-service architecture rather than writing every line solo — a skill that
matters more as the target moves from "engineer" toward "technical co-founder."

## Timeline

3-5 days (extended from an original 1-2 day CLI-only scope to accommodate the 3-service
architecture below). Prioritize a working end-to-end path (Phase 1) before polishing any
single service.

## Background context for the agent

- IELTS Task 2 is scored on 4 criteria, each 0-9 in 0.5 increments, averaged (with rounding
  rules) to an overall band:
  1. Task Response (TR)
  2. Coherence and Cohesion (CC)
  3. Lexical Resource (LR)
  4. Grammatical Range and Accuracy (GRA)
- The official band descriptors (public, from IELTS/British Council) must be sourced and
  embedded into the system prompt so scoring is grounded in real criteria, not vague LLM
  judgment. Do not paraphrase the rubric from memory — fetch the actual descriptor text.
- The person building this holds an IELTS band 7-8 themselves and will manually validate
  scores against known-good essays, so the eval step matters more than UI polish.
- The person's day job stack is Go/Node.js backend; this project is intentionally using
  Go for the backend and Python only for the LLM-facing piece, to practice a polyglot
  service boundary.

## Architecture

Three services:

1. **Frontend (React)** — essay input, either pasted text or an uploaded PDF (extract text
   client-side or send the PDF to Go for extraction — Go's choice, simplest option wins).
   Submits a scoring job, polls for and displays the result.
2. **Backend (Go / Gin)** — owns auth, storage (essays + results), and job orchestration.
   Receives submissions from React, publishes a scoring job, stores results when ready,
   serves them back to React.
3. **LLM worker (Python / FastAPI + worker process)** — consumes scoring jobs, calls the
   LLM provider, returns structured results.

**Go <-> Python communication: message queue (Redis).**
This is more infrastructure than a simple synchronous HTTP call would be — flagged
explicitly so the agent doesn't skip it or accidentally simplify back to direct HTTP without
saying so. Default pattern (change only if the person says otherwise):

- Redis list or stream as the queue. Gin pushes a job (job_id, prompt, essay text) onto it.
- A Python worker process (separate from the FastAPI app, or a background task within it)
  pops jobs, runs the scoring pipeline, writes the result to Redis (or directly to Go's
  database, if simpler) keyed by job_id.
- React polls `GET /jobs/:id` on the Gin API every ~2s until status is `done`, then renders
  the result. No websockets needed for a project this size — polling is simpler and fine.
- Keep the worker logic simple: no retries/dead-letter queues/etc. — this is a learning
  project, not a production queue system. If Redis setup becomes a time sink, it's fine to
  fall back to a synchronous Go->Python HTTP call and note that trade-off in the README,
  but attempt the queue version first since that was the explicit goal.

## Tech stack

- **Frontend**: React, plain fetch/axios for HTTP. PDF text extraction: simplest available
  library (client-side or via a Go endpoint — agent's choice).
- **Backend**: Go + Gin. **Database: PostgreSQL with the `pgvector` extension.**
- **Auth**: single hardcoded user. One password, bcrypt-hashed and stored (not plaintext,
  not in source control — read from env var or a local config file). A login endpoint that
  checks the password against the hash and returns a simple session token or signed cookie.
  No user table, no registration flow, no multi-user support — this is a gate, not an auth
  system.
- **LLM worker**: Python 3.11+, FastAPI, `pydantic` for the structured output schema,
  `python-dotenv` for config, `redis` client library.
- **LLM provider**: OpenAI-compatible endpoint (base_url + api_key + model read from
  `.env`) — keep this swappable, since the person has been bouncing between
  DeepSeek/Groq/Gemini/Qwen due to account access issues. Do not hardcode a single
  provider's SDK.

## Database schema (PostgreSQL + pgvector)

- `essays` table: id, prompt_text, essay_text, created_at, and an `embedding vector(N)`
  column (dimension N matches whichever embedding model is used — confirm the provider's
  embedding model output size before creating the column).
- `results` table: id, essay_id (FK), the 4 criterion scores + feedback (JSONB is fine for
  the nested structure), overall_band, created_at.
- `jobs` table: id, essay_id (FK), status (pending/processing/done/failed), created_at,
  completed_at — this is what React polls against.
- On essay submission: generate an embedding for the essay text (same LLM provider's
  embedding endpoint, or a separate lightweight embedding model — agent's choice, note
  which was used in the README) and store it alongside the essay.
- **Similarity search feature**: an endpoint (e.g. `GET /essays/:id/similar`) that uses
  pgvector's cosine/L2 distance operator to find the N most similar previously-scored
  essays. Surface this in the React UI as "similar essays you've submitted" on the results
  page — a small but real feature, not just a schema column that goes unused.
- Keep this scoped: no reranking, no chunking (essays are short enough to embed whole), no
  external vector DB — pgvector inside the same Postgres instance is sufficient.

## Phase 1 — End-to-end skeleton (get something working first)

Before building out scoring quality or UI polish, get the full path working with a stubbed
scorer (returns a hardcoded fake score) so the architecture is proven:

1. React form → POST to Gin → Gin pushes to Redis → Python worker picks it up → writes a
   fake result back → React polls and displays it.
2. This proves the queue/polling mechanism works before any LLM cost or prompt-engineering
   time is spent on it.

## Phase 2 — Real scoring pipeline

1. **Rubric grounding**: fetch/store the official IELTS Task 2 band descriptor text (all 4
   criteria, band 1-9 language) as a local reference file. Inject into the system prompt on
   every call.
2. **Structured output schema** (pydantic):

   ```python
   class CriterionScore(BaseModel):
       band: float          # 0-9, 0.5 increments
       feedback: str        # specific, references actual essay content
       quoted_issues: list[str]  # short excerpts from the essay illustrating the score

   class EssayScore(BaseModel):
       task_response: CriterionScore
       coherence_cohesion: CriterionScore
       lexical_resource: CriterionScore
       grammatical_range_accuracy: CriterionScore
       overall_band: float
       summary: str
   ```

3. **Scoring call**: system prompt = rubric + scoring instructions ("cite specific phrases
   from the essay, don't give generic praise"); user message = the prompt + essay; use
   JSON mode / structured output to get the schema back reliably.
4. Wire this real scorer in to replace the Phase 1 stub.
5. **Test set**: assemble 3-5 sample essays with known real band scores (person will supply
   these, or use publicly available graded IELTS sample essays).

## Phase 3 — Evaluation & consistency

LLM essay scoring is known to be inconsistent (same essay can score differently on rerun)
and tends to be overly generous. This phase is a core learning goal of the project, not an
afterthought — don't skip it for UI polish.

1. Run each test essay through the scorer **3 times**, log all runs, measure variance per
   criterion. Flag if variance > 0.5 band on any criterion.
2. Compare average score against the known real band score for each test essay. Report
   delta.
3. Try adding 1-2 few-shot examples (a real essay + its real official band breakdown) into
   the prompt and re-run the eval — measure whether this reduces variance or improves
   accuracy. This before/after comparison is one of the most valuable outputs of the whole
   project.
4. Write findings to a short `EVAL.md`: variance numbers, accuracy vs known scores,
   before/after few-shot comparison.

## Phase 4 — Polish (only after Phases 1-3 work)

1. Store essay history per session so past results can be revisited.
2. Wire up the similarity search endpoint and surface it in the UI ("similar essays you've
   submitted before").
3. Basic logging: token usage and latency per call.
4. Reasonable loading/error states in the React UI while a job is in progress.

## Explicit non-goals (keep scope from creeping further)

- No multi-user accounts, no registration flow
- No production-grade queue features (retries, dead-lettering, backoff)
- No fine-tuning or training — this is prompt engineering + eval only
- No Task 1 (image-based scoring) — separate future project
- No deployment/hosting — local dev is sufficient

## Deliverable

A working local app (React frontend, Gin backend, Redis queue, Python scoring worker,
Postgres+pgvector storage with a working essay-similarity feature), an eval report
(`EVAL.md`) showing measured consistency/accuracy against known scores, and a `README.md`
covering setup (Redis + Postgres/pgvector) and what the eval found.
