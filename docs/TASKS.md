# Tasks — build order and agent prompts

Paste-ready prompts, one per agent session, in order. ✍ marks work the developer does
before starting the task.

## How to run a task

1. Start a **fresh agent session** per task. For Claude Code, copy or symlink `AGENTS.md`
   to `CLAUDE.md`; for Gemini, to `GEMINI.md`.
2. Paste the prompt.
3. Review the diff. Check that the real test output is pasted. Commit. Next task.
4. If the agent goes off track, don't argue in the same session. Revert, tighten the
   prompt, start fresh.

## Order

| Group | Tasks | Result |
|---|---|---|
| Scorer | T0-T4 | Score one essay from the terminal (P3 only) |
| Eval | T5 | Baseline numbers, evidence off |
| Evidence | T6-T9 | Features + checklist; eval evidence off vs on |
| Web stack | T10-T12 | Client → server → Redis → worker → back. Can start any time after T4 |
| Later | L1-L5 | Only when the eval shows a gap (L1-L4) or for polish (L5) |

Tests never use hand-marked essays. Feature tests are **property tests**: constructed text
whose answer is unambiguous by construction.

---

## T0 — Worker scaffold

```
Read AGENTS.md and docs/SCORING.md §4.2.
Task: scaffold the Python worker.
- worker/pyproject.toml (Python 3.11+), installable with `pip install -e worker`:
  spacy, wordfreq, language_tool_python, sentence-transformers, pydantic, openai,
  python-dotenv, redis, scipy, scikit-learn, pytest.
  Setup note in worker/README.md: `python -m spacy download en_core_web_sm` (never at
  import time).
- Empty packages: worker/features, worker/checklist, worker/scoring, worker/tests
  (+ tests/fixtures), and evaluator/ at the repo root.
- worker/features/lt_client.py: thin wrapper over LANGUAGETOOL_URL (remote_server).
  check(text, lang) -> list of matches with category id, message, offset, length.
- Add worker/.cache/ to .gitignore.
- Test: LanguageTool (en-GB) finds at least one GRAMMAR match in "He go to school yesterday."
Out of scope: any feature logic.
```

## T1 — Rubric

**Done 2026-09-23.** `rubric/task2_band_descriptors.md` and `rubric/SOURCE.md` are in
place, and the findings are in `SCORING.md` §3 and §10. Kept for reference:

```
Read AGENTS.md and docs/SCORING.md §3.
Task: fetch the official public IELTS Writing Task 2 band descriptors (all four criteria,
bands 0-9) from ielts.org, the British Council or IDP.
- Save the text verbatim to rubric/task2_band_descriptors.md. Don't paraphrase or fix
  wording. Keep the official structure (criterion → band → descriptor).
- rubric/SOURCE.md: URL, document title/version, retrieval date.
- Report, quoting the descriptor text: does it support SCORING.md §3's pre-checks
  (≤20 words → band 1; band 0 cases)? Does it say anything about non-English responses
  (SCORING.md §10.1)? Don't change SCORING.md. Just report.
- If you can't reach an official source, stop and tell me. Never write descriptors from memory.
Out of scope: code.
```

## T2 — LLM client

```
Read AGENTS.md and docs/SCORING.md §6 (intro) and §9.
Task: worker/scoring/llm.py exactly as SCORING.md §9: call_json, prompt file loading with
string.Template and ---USER---, response_format fallback, one pydantic repair call,
429 handling with Retry-After, the disk cache keyed by cache_tag, call_meta, and
quotes_verified.
Tests (mock the openai client, no network): success; invalid-then-repaired;
invalid-twice-raises; response_format rejected → retried without; 429 with Retry-After →
retried once; 429 without → raises; cache hit makes no call and sets cached=true;
cache_tag=None never writes the cache; a prompt containing literal JSON braces renders;
a missing variable raises; quotes_verified normalises whitespace and case.
Out of scope: prompt contents.
```

## T3 — Shared preprocessing

```
Read AGENTS.md and docs/SCORING.md §4.1.
Task: worker/features/text.py: word_count, sentences, paragraphs, content_lemmas.
spaCy loaded once at module level.
Tests (write the inputs so the answer is obvious by construction):
- word_count: "Hello , world ." → 2; "" → 0; "well-known  e.g. 3.5%" → 3; newlines/tabs as spaces.
- paragraphs: text with 1, 2 and 3 blank-line-separated blocks, including trailing blank lines
  and lines of only spaces.
- sentences: short declarative sentences ending in ". " give the expected count.
- content_lemmas: "The children were running quickly." contains child, run, quickly and no stopwords.
Out of scope: other features.
```

## T4 — Judge, band math, pipeline, CLI

```
Read AGENTS.md and docs/SCORING.md (all of it).
Task:
- scoring/schemas.py: all models in §8.1.
- scoring/bands.py: round_writing_band, criterion_confidence, overall_confidence,
  display_headline, SUGGESTIVE_FROM (§7) and the pre-checks (§3).
- worker/prompts/judge.v1.txt: P3 copied verbatim from §6.3.
- scoring/evidence.py: render_evidence(features, checklist) -> str per §6.3. With empty
  inputs it returns "".
- scoring/pipeline.py: score(prompt_text, essay_text, evidence=True, fewshot=None,
  cache_tag=None, on_stage=None) per §2, returning the §8.2 dict. For now the features
  and checklist stages call placeholders that return {}. Later tasks fill them in.
- scoring/cli.py: python -m scoring.cli --prompt p.txt --essay e.txt [--no-evidence]
  prints the result JSON.
Tests: every band-math example in §7 (table-driven); all 4 pre-check rows including the
exact boundaries (0, 20, 21, 249, 250 words); display_headline for each confidence;
pipeline with a mocked LLM for a scored essay (quotes_verified filled, overall computed in
code even if the mock returns an extra "overall_band" key), a rejected essay and a
too_short essay (no LLM call made); the fewshot block is rendered when given.
Then run the CLI once for real on any essay and paste the output.
Out of scope: features, checklist, queue, eval.
```

## T5 — Eval runner

✍ Before starting: collect the official graded essays into `evaluator/data/essays.jsonl`
(`EVALUATION.md` §2). Mark 1-2 dev essays with all four bands as `fewshot: true`. Look up
your model's training cutoff.

```
Read AGENTS.md and docs/EVALUATION.md (all of it).
Task: evaluator/run_eval.py and evaluator/metrics.py exactly as EVALUATION.md:
flags (§5), cutoff split and near-duplicate warning (§3), few-shot handling (§4), all
metrics with n and bootstrap intervals (§6), dry-run (§7), outputs (§8).
Call scoring.pipeline.score with cache_tag=f"run{n}".
Tests: every metric function against small hand-computed examples written in the test
(MAE only on true 0-7; adjacent; median of runs; false-8 rate; suggestive precision;
run-to-run variation); QWK equals sklearn's on a small example; split assignment around
the cutoff month; fewshot essays excluded from metrics; bootstrap is deterministic with the
fixed seed.
Then run: --dry-run, then --evidence off --fewshot off on dev. Paste both outputs and the
report path.
Out of scope: editing EVAL.md.
```

## T6 — Grammar features

```
Read AGENTS.md and docs/SCORING.md §4.2-§4.3 (gra.* rows).
Task: worker/features/grammar.py: every gra.* key. Use lt_client and text.py.
Tests (constructed sentences, answer unambiguous by construction):
- complex: "The man who lives next door is a doctor." (relcl) → complex;
  "Because it rained, we stayed home." (advcl) → complex; "I like tea." → not complex.
- clause_types: conditional counted for "If it rains, we will stay home."; not for
  "I wonder if he knows." ; passive counted for "The window was broken."
- errors: "He go to school yesterday." has ≥1 grammar match; "She goes to school every day."
  has none; error_free_sentence_ratio of those two together = 0.5.
- Any null-denominator case returns null.
If spaCy's parse disagrees with a constructed case, stop and show the parse. Don't
change the case.
Out of scope: thresholds, LLM calls.
```

## T7 — Lexis features (core)

```
Read AGENTS.md and docs/SCORING.md §4.2-§4.3 (lr.* rows).
Task: worker/features/lexis.py: lr.rare_word_ratio, lr.spelling_errors_per_100w,
lr.prompt_overlap_ratio, lr.top_repetition.
Tests:
- rare_word_ratio: a text of very common words ("people think good things are important")
  is lower than one of rare words ("ubiquitous surveillance engenders pernicious conformity").
- spelling: "recieve" counts; "colour" and "color" each count 0 (the en-GB ∩ en-US rule).
- prompt_overlap_ratio: an essay that copies the prompt verbatim → 1.0; an essay sharing no
  3-gram → 0.0.
- top_repetition: counts on a constructed text.
Out of scope: L1/L2 features.
```

## T8 — Cohesion features (core)

✍ Review `features/data/linkers.json` line by line after the agent drafts it (categories:
addition, contrast, cause_effect, example, sequence, conclusion).

```
Read AGENTS.md and docs/SCORING.md §4.3 (cc.* rows).
Task: draft worker/features/data/linkers.json, then worker/features/cohesion.py: every core
cc.* key.
Tests: every sentence starting with a linker → sentence_initial_linker_ratio = 1.0; no
blank lines → paragraph_count = 1; "on the other hand" counted once as one contrast linker,
not also as "other"; "However" and "however" both match; "whatever" doesn't match "what".
Out of scope: cc.adjacent_similarity_mean, cc.paragraph_central_idea.
```

## T9 — Checklist + evidence wiring

```
Read AGENTS.md and docs/SCORING.md §2, §5, §6.1-§6.3, §9.
Task:
- worker/prompts/task_parts.v1.txt and task_analysis.v1.txt: P1 and P2 copied verbatim.
- worker/checklist/task.py: run P1 (cache_tag="p1"), then P2 with the pipeline's cache_tag.
  Fill quote_verified on every quote. Return the §5 keys.
- Replace the T4 placeholders in pipeline.py with the real features (T6-T8) and
  checklist, so render_evidence gets real inputs.
Tests (mocked LLM): P1 is called once for two essays on the same question; quote_verified is
false for a quote not in the essay; P2's "no" parts have empty quotes; the evidence block
contains the Task line; with evidence=False no P1/P2 call is made.
Then run the eval: --evidence both --fewshot off on dev. Paste the report path and the
evidence off vs on table.
Out of scope: P4, P5.
```

## T10 — Server: config, DB, auth

```
Read AGENTS.md and docs/SPEC.md §4, §5, §8, §9 (login row).
Task: server/ Go module. cmd/api/main.go; internal/{config,db,auth}; migrations/00001_init.sql
exactly as SPEC §8 (goose). Env load order per §4. Startup upserts the admin hash. POST
/api/login and the auth middleware per §5.
Tests (go test ./...): cookie sign/verify, expired cookie rejected, tampered cookie
rejected, middleware 401. Paste `goose up` output and a curl login (204 then 401 with a
wrong password).
Out of scope: essays, jobs, queue.
```

## T11 — Queue round trip

```
Read AGENTS.md and docs/SPEC.md §6, §7, §9.
Task:
- server: POST /api/essays, GET /api/jobs/:id, the result consumer and the timeout sweeper,
  exactly per SPEC §6-§7.
- worker/embedding.py (EMBEDDING_MODEL, normalised, loaded once) and worker/main.py (the
  worker loop in SPEC §6).
Tests: go test for the consumer's persist function (a replay of the same message is a
no-op) against the docker Postgres; pytest for main.py's message handling with
scoring.pipeline.score mocked.
Check, pasted: POST an essay with curl → poll until done → the results row exists and
essays.embedding is not null. Then stop the server mid-job, restart it, and show that the
pending result is still persisted.
Out of scope: client, history, similarity.
```

## T12 — Client + history + similarity

```
Read AGENTS.md, docs/SPEC.md §9-§10 and docs/SCORING.md §7 (UI display).
Task:
- server: GET /api/essays, GET /api/essays/:id, GET /api/essays/:id/similar (SPEC §9 query).
- client: replace the Vite template with the SPEC §10 screens. Vite proxy for /api.
  Display rules from SCORING §7.
Check, pasted: `npm run build` and `npm run lint` output, go test output, and a
description of submitting an essay end to end in the browser.
Out of scope: PDF upload.
```

---

## Later (only when the eval shows a gap)

- **L1 — MTLD + CEFR:** `lr.mtld`, `lr.cefr_distribution` (add `lexicalrichness` and
  `cefrpy`) plus their evidence clauses. Re-run the dev eval against the previous report.
- **L2 — Collocations:** `lr.collocation_candidates`, P4 (`collocations.v1.txt`),
  `lr.collocations_judged`, `lr.unnatural_collocation_rate` plus the evidence clause.
- **L3 — Cohesion/relevance:** `cc.adjacent_similarity_mean`, P5 (`paragraph_ideas.v1.txt`)
  → `cc.paragraph_central_idea`, `tr.paragraph_relevance` plus evidence clauses.
- **L4 — Calibration and conflict flags:** `evaluator/calibrate.py` derives per-feature
  cut-offs from dev (the features with a meaningful Spearman correlation in the reports).
  Then `scoring/conflicts.py` flags an LLM band that disagrees with the features. Thresholds
  are proposed by the script and approved by the developer, never hardcoded by an agent.
- **L5 — PDF upload:** client-side text extraction (`pdfjs-dist`) into the essay textarea.
