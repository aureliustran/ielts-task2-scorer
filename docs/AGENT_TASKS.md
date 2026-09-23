# Agent Task Prompts — scoring pipeline

These are paste-ready prompts for your coding agent, one per session, in order. They
cover the scoring side (Phases 2-3). Build the Phase 1 skeleton (React → Gin → Redis →
worker stub) first, or in parallel. The worker here runs standalone from a CLI, so it
doesn't depend on the queue.

## How to run each task
1. Start a **fresh agent session** for each task, so context from one task doesn't leak
   into the next.
2. Paste the task prompt. The agent reads `AGENTS.md` automatically (for Claude Code,
   copy or symlink it to `CLAUDE.md`; for Gemini/Antigravity, to `GEMINI.md`).
3. **Before T2-T4, write the fixture expectations yourself** (the ✍ steps). You're the
   IELTS expert: hand-checked expected values are what stop the agent from writing code
   that passes its own made-up tests.
4. Review the diff. Check that it ran `pytest` and pasted real output. Commit. Next task.
5. If the agent goes off track, don't argue in the same session. Revert, tighten the
   prompt, start fresh.

---

## T0 — Worker scaffold + LanguageTool

```
Read AGENTS.md and docs/FEATURES.md.
Task: scaffold the Python worker and add LanguageTool to docker-compose.
- Create worker/ with pyproject.toml (Python 3.11+): spacy, lexicalrichness, wordfreq,
  cefrpy, language_tool_python, sentence-transformers, pydantic, openai, python-dotenv,
  pytest. Download en_core_web_sm in a setup note, not at import time.
- Create empty packages worker/features, worker/checklist, worker/scoring and
  worker/tests/fixtures.
- Add a `languagetool` service to docker-compose.yml (image erikvl87/languagetool,
  port 8010:8010). Keep the existing postgres and redis services unchanged.
- worker/features/lt_client.py: a thin wrapper that connects to LANGUAGETOOL_URL from
  .env and returns matches with category ids.
- One test: LanguageTool finds at least one match in "He go to school yesterday."
Out of scope: any feature logic.
```

## T1 — Shared preprocessing

✍ Before starting, write `worker/tests/fixtures/text_basic.json`: 2 short essays
(3 paragraphs, 6-8 sentences each) with the word count, sentence count and paragraph count
you counted by hand.

```
Read AGENTS.md and docs/FEATURES.md section 0.
Task: implement worker/features/text.py exactly as defined (word_count, sentences,
paragraphs, content_lemmas). Load spaCy once (module-level cache).
Tests: use worker/tests/fixtures/text_basic.json. Don't edit its expected values. If you
think one is wrong, stop and tell me which and why.
Out of scope: other features.
```

## T2 — Grammar features

✍ Write `worker/tests/fixtures/grammar_sentences.json`: about 15 single sentences, each
labelled by you with `is_complex` (bool), `clause_types` (list) and `has_error` (bool).
Include tricky cases: a relative clause without "that", a passive with no agent, an
"if" that isn't conditional ("I wonder if..."), an error-free long sentence, a
short sentence with an error.

```
Read AGENTS.md and docs/FEATURES.md section 1.
Task: implement worker/features/grammar.py producing every gra.* key exactly as defined.
Use features/lt_client.py for LanguageTool, and features/text.py for sentences.
Tests:
- Per-sentence checks against worker/tests/fixtures/grammar_sentences.json. Report
  accuracy per field. Don't edit fixture values.
- The complex/clause detection must reach 100% on the fixture, or stop and list the
  failing sentences with spaCy's parse, so I can decide whether the definition or the
  fixture is wrong.
- has_error vs LanguageTool may disagree. Report the disagreements, don't hide them.
Out of scope: thresholds, bands, LLM calls.
```

## T3 — Lexical features

✍ Write `worker/tests/fixtures/lexis.json`: one plain essay (simple, repetitive
vocabulary) and one rich essay (varied, less common words), plus 10 word pairs you've
labelled as natural or unnatural collocations.

```
Read AGENTS.md and docs/FEATURES.md section 2.
Task: implement worker/features/lexis.py for all lr.* keys of type C (not
lr.collocations_judged, which is T6).
Tests:
- lr.mtld and lr.rare_word_ratio are higher for the rich essay than the plain one.
- collocation extraction finds the expected pairs in fixture sentences.
- lr.prompt_overlap_ratio > 0.3 for a test essay that copies whole phrases of its prompt,
  and < 0.1 for one that doesn't.
Out of scope: LLM judgment, thresholds.
```

## T4 — Cohesion features

✍ Write `features/data/linkers.json` yourself (or review the agent's draft, line by line):
categories → list of linking expressions. You know which ones IELTS examiners see as
overused.

```
Read AGENTS.md and docs/FEATURES.md section 3.
Task: implement worker/features/cohesion.py for all cc.* keys of type C.
Use the linker lexicon at features/data/linkers.json. Match multi-word linkers before
single words, case-insensitive, whole-word only.
Load the sentence-transformers model once. Make the model name a config value.
Tests: a fixture essay where every sentence starts with a linker gives
sentence_initial_linker_ratio = 1.0; an essay with no blank lines gives paragraph_count = 1.
Out of scope: cc.paragraph_central_idea (T6).
```

## T5 — LLM client

```
Read AGENTS.md and docs/LLM_PROMPTS.md (the shared rules at the top).
Task: implement worker/scoring/llm.py:
- call_json(prompt_name, version, variables, schema: type[BaseModel]) -> BaseModel
- Loads worker/prompts/{prompt_name}.v{version}.txt (system and user parts separated by
  a line containing only ---USER---). Fills variables.
- Uses the openai client with LLM_BASE_URL, LLM_API_KEY, LLM_MODEL and LLM_TEMPERATURE
  from .env. Requests JSON output. If the provider rejects response_format, retry once
  without it.
- Validates with pydantic. On failure, one repair call that includes the validation
  error. Then raise.
- Returns the result plus {model, prompt_version, input_tokens, output_tokens,
  latency_ms}.
- quotes_verified(quotes, essay) as defined in docs/SCORING_RULES.md.
Tests: mock the HTTP client. Cover success, invalid-then-repaired, invalid-twice-raises,
and response_format-unsupported fallback.
Out of scope: writing prompt contents (next task).
```

## T6 — Checklist questions

```
Read AGENTS.md, docs/FEATURES.md sections 2-4 and docs/LLM_PROMPTS.md P1-P5.
Task: implement worker/checklist/ (task.py, lexis.py, cohesion.py) using scoring/llm.py.
- Copy prompts P1-P5 verbatim into worker/prompts/*.v1.txt. Don't reword them.
- A pydantic schema for each response, as specified.
- P1 results cached on disk by sha256(prompt_text).
- Run quotes_verified on every quote field. Store the result next to it.
- Compute lr.unnatural_collocation_rate after P4.
Tests: mocked LLM responses. Plus one opt-in live test (pytest -m live) that runs P1-P5
on one fixture essay and prints the output for me to read.
Out of scope: band scoring.
```

## T7 — Band math + evidence-grounded scoring

```
Read AGENTS.md, docs/SCORING_RULES.md and docs/LLM_PROMPTS.md P6.
Task:
- worker/scoring/bands.py: round_writing_band, criterion_confidence, overall_confidence,
  display_headline, SUGGESTIVE_FROM, exactly as in SCORING_RULES.md, plus the
  deterministic pre-checks (empty / <=20 words / underlength).
- worker/scoring/pipeline.py: score(prompt_text, essay_text, evidence=True) runs the
  pre-checks → features → checklist → P6 → band math, and returns the full stored-result
  JSON (SCORING_RULES.md section 6), including "features".
- With evidence=False, P6 gets no MEASURED EVIDENCE block (the ablation switch).
- CLI: python -m scoring.cli --prompt p.txt --essay e.txt [--no-evidence]
Tests: table-driven tests for every band math example in SCORING_RULES.md, plus
pre-check tests. The pipeline is tested with a mocked LLM.
Out of scope: Redis/queue wiring, eval.
```

## T8 — Eval runner

✍ Put your scored essays in `eval/data/essays.jsonl`: {id, prompt, essay, true: {tr, cc,
lr, gra}, source}. Mark any essay used as a few-shot example with `"fewshot": true`.

```
Read AGENTS.md, docs/SCORING_RULES.md section 7 and docs/OVERVIEW.md Phase 3.
Task: eval/run_eval.py
- Args: --runs N (default 5), --evidence on|off|both, --exclude-fewshot (default on).
- Calls scoring.pipeline.score for each essay × run. Logs every raw result to
  eval/results/{timestamp}/runs.jsonl.
- Computes per criterion: quadratic weighted kappa, exact and adjacent (±1) agreement,
  and MAE on true band 0-7 only; run-to-run variance (flag any band change); suggestive
  precision; false-8 rate; quote verification rate; Spearman correlation of every numeric
  feature with the true band.
- Writes eval/results/{timestamp}/report.md. With --evidence both, puts the two
  conditions side by side.
Tests: metric functions against small hand-computed examples.
Out of scope: editing EVAL.md (I write the findings myself from the report).
```
