# Scoring — pipeline, features, prompts, band math

The contract for everything in `worker/`. Feature keys, prompt text, schemas and the
stored-result shape must match this file exactly.

## 1. Principles

1. **Match real IELTS mechanics.** Examiners give each criterion a whole band. Half bands
   only appear in the overall band, after averaging and rounding.
2. **The LLM judges, the code calculates.** The model returns four criterion bands plus
   evidence. Code computes the overall band, the rounding, confidence flags and quote
   checks, and never trusts model arithmetic or counting.
3. **Be honest about what a cheap model can do.** Bands 0-7 are the working range. Telling
   7, 8 and 9 apart needs fine judgments ("rare errors", "skilful") that cheap models make
   poorly, and LLMs lean generous. Any 8 or 9 is stored as given but shown as
   **suggestive**.
4. **Measure before adding.** Features and prompts beyond the core set are added only when
   the eval shows a gap they could close (`EVALUATION.md`).
5. **No invented numbers.** No band thresholds for features until they are calibrated from
   the eval set.

## 2. Pipeline

`scoring.pipeline.score(prompt_text, essay_text, evidence=True, fewshot=None, cache_tag=None) -> dict`
returns the stored result (§8). The worker calls it with the defaults. The evaluator sets
`evidence`, `fewshot` and `cache_tag`.

| # | Stage | Module | LLM calls | Runs when |
|---|---|---|---|---|
| 1 | `precheck` | `scoring/bands.py` | 0 | always |
| 2 | `features` | `features/*` | 0 | `evidence=True` |
| 3 | `checklist` | `checklist/task.py` | P1 (cached per question) + P2 | `evidence=True` |
| 4 | `judge` | `scoring/pipeline.py` | P3 | pre-check didn't short-circuit |
| 5 | `postprocess` | `scoring/bands.py` | 0 | always |

- A pre-check short-circuit (§3) skips stages 2-4.
- With `evidence=False` only P3 is called: that's the ablation baseline.
- `fewshot` is a list of eval-set essays with official bands, rendered into P3 (§6.3).
- The worker's defaults are `evidence=True, fewshot=None`. After the final eval run, change
  them to the best condition (Follow-up).
- The pipeline takes an `on_stage(name)` callback, which the worker uses to update
  `job:{id}`.
- Stage durations go into `stage_ms` in the result.
- The embedding for similarity search is computed by the worker (`worker/embedding.py`),
  outside `score()`.

## 3. Deterministic pre-checks (before any LLM call)

`word_count` = `features.text.word_count` (§4.1): whitespace-split tokens, excluding pure
punctuation. It is the one definition used everywhere. Always computed in code and passed
to the model.

| Condition | `status` | Criterion bands | LLM |
|---|---|---|---|
| `word_count == 0` | `rejected` | all 0 | not called |
| `word_count <= 20` | `too_short` | all 1 | not called |
| `word_count < 250` | `scored` | from P3 | called with `underlength=true` |
| otherwise | `scored` | from P3 | called |

- **Checked against the rubric (T1, `rubric/task2_band_descriptors.md`):**
  - ≤20 words → band 1: confirmed. "Responses of 20 words or fewer are rated at Band 1"
    appears in bold under all four criteria.
  - Empty → band 0: confirmed. Band 0 applies where a candidate "did not attend or attempt
    the question in any way".
  - Band 0 also covers "used a language other than English throughout" (§10.1) and proven
    total memorisation. Memorisation needs proof the scorer can't have, so it's out of scope.
- Under 250 words there's no fixed deduction, and the rubric mentions length only in
  qualitative terms (LR band 3 "significantly underlength", GRA band 3 "Length may be
  insufficient"). Task Response judges it, and the UI shows an "under 250 words" warning.
- The rubric says "Any copied rubric must be discounted" (TR band 1). `word_count`
  currently includes text copied from the question (open question §10.4).

## 4. Features (deterministic, `features/`)

No LLM calls and no network except the local LanguageTool. Same input → same output.
Stored flat in `result.features` under these exact keys. A ratio whose denominator is 0 is
`null`.

### 4.1 Shared preprocessing — `features/text.py` (spaCy `en_core_web_sm`, loaded once)
| Key | Definition |
|---|---|
| `word_count` | Whitespace-split tokens, excluding tokens made only of punctuation |
| `sentences` | spaCy sentence split (not stored in `features`) |
| `paragraphs` | Split on one or more blank lines, empties stripped (not stored) |
| `content_lemmas` | Lemmas of NOUN/VERB/ADJ/ADV tokens, lowercased, stopwords removed (not stored) |

### 4.2 LanguageTool rules — `features/lt_client.py`
- Talks to `LANGUAGETOOL_URL` through `language_tool_python` (`remote_server=`).
- **Grammar and punctuation:** the `en-GB` check, categories `GRAMMAR` and `PUNCTUATION`,
  kept as a module constant `GRA_CATEGORIES`.
- **Spelling:** category `TYPOS`. A spelling match counts only if the same span is flagged
  by **both** `en-GB` and `en-US`, because IELTS accepts either spelling.
- All other categories are ignored.

### 4.3 Core features (built in T6-T8)
| Key | Definition |
|---|---|
| `gra.error_free_sentence_ratio` | Share of sentences with zero grammar/punctuation matches |
| `gra.errors_per_100w` | Grammar + punctuation matches ÷ word_count × 100 |
| `gra.complex_sentence_ratio` | Share of sentences containing ≥1 token with dep in {advcl, ccomp, relcl, acl, xcomp} or a `mark` dependency |
| `gra.clause_types` | Counts `{relative: relcl, adverbial: advcl, conditional: mark is "if"/"unless" attached to an advcl, passive: nsubjpass or auxpass}` |
| `gra.mean_sentence_length` | word_count ÷ number of sentences |
| `gra.clauses_per_sentence` | Finite verbs heading a clause (VERB/AUX with a `VerbForm=Fin` morph, or ROOT verbs) ÷ sentences |
| `gra.error_examples` | Up to 5 grammar/punctuation matches: `{sentence, message, offset}` |
| `lr.rare_word_ratio` | Share of content lemmas with `wordfreq.zipf_frequency(w, "en") < 4.0`. The 4.0 is a measurement cut-off, not a band threshold |
| `lr.spelling_errors_per_100w` | Spelling matches (§4.2) ÷ word_count × 100 |
| `lr.prompt_overlap_ratio` | Share of the essay's lowercased word 3-grams that also occur in the prompt |
| `lr.top_repetition` | The 5 most frequent content lemmas: `[[lemma, count], ...]` |
| `cc.paragraph_count` | len(paragraphs) |
| `cc.paragraph_word_counts` | word_count of each paragraph |
| `cc.linker_counts` | Counts by category (addition, contrast, cause_effect, example, sequence, conclusion) from `features/data/linkers.json`. Multi-word linkers are matched before single words; case-insensitive, whole-word |
| `cc.linkers_per_100w` | Total linkers ÷ word_count × 100. **Not monotonic:** high can mean mechanical overuse |
| `cc.linker_distinct` | Number of distinct linkers used |
| `cc.sentence_initial_linker_ratio` | Share of sentences that start with a linker |

### 4.4 Later features (only if the eval shows a gap; tasks L1-L3)
| Key | Definition |
|---|---|
| `lr.mtld` | MTLD over lowercased word tokens (`lexicalrichness`) |
| `lr.cefr_distribution` | Share of content lemmas per CEFR level A1-C2 (`cefrpy`), with unknown kept separate |
| `lr.collocation_candidates` | spaCy pairs amod (ADJ+NOUN), dobj (VERB+NOUN), advmod (ADV+ADJ). Up to 30, deduplicated, with sentence context |
| `lr.collocations_judged` | P4 output per candidate |
| `lr.unnatural_collocation_rate` | unnatural ÷ judged (`null` if none judged) |
| `cc.adjacent_similarity_mean` | Mean cosine similarity of adjacent sentence embeddings (`EMBEDDING_MODEL`) |
| `cc.paragraph_central_idea` | P5 output per paragraph |
| `tr.paragraph_relevance` | Cosine similarity of each paragraph embedding to the prompt embedding |

## 5. Checklist (narrow LLM questions, `checklist/task.py`)

Stored in `result.checklist`. None of these prompts asks for a band.

| Key | From | Content |
|---|---|---|
| `tr.prompt_parts` | P1 | The question's required parts. Cached by the LLM cache (§9) with a fixed tag, so the same question always gets the same parts |
| `tr.parts_addressed` | P2 | Per part: `{id, addressed: fully\|partly\|no, evidence_quote, quote_verified}` |
| `tr.position` | P2 | `{stated_in_intro, stated_in_conclusion, consistent_throughout, position_quote, quote_verified}` |
| `tr.main_ideas` | P2 | `[{idea, developed, has_example, quote, quote_verified}]` |
| `tr.underlength` | code | word_count < 250 |

`quote_verified` is computed by `quotes_verified` (§9). A failed quote is kept but marked.

## 6. Prompts

Files: `worker/prompts/{name}.v{N}.txt`, with the system part, then a line containing only
`---USER---`, then the user part. Placeholders use `string.Template` syntax (`$name`), so
literal JSON braces in the prompts are safe. Every variable is a pre-formatted string built
in code. **Never edit a prompt file after it has been used in an eval run; create `v2`.**
Copy the text below into the v1 files verbatim.

### 6.1 P1 — `task_parts` (question → required parts)

```
You analyse IELTS Writing Task 2 questions. List every separate thing the question
requires the writer to do. Don't evaluate any essay.
Return JSON: {"parts": [{"id": "p1", "requirement": "..."}]}
Rules:
- One requirement per item (e.g. "discuss view A", "discuss view B", "give own opinion").
- Include an implicit requirement only if the question type always demands it (e.g. an
  agree/disagree question requires a clear position).
- 1 to 5 parts. No commentary.
---USER---
Question: $prompt_text
```

### 6.2 P2 — `task_analysis` (coverage, position, main ideas — one call)

```
You map how an IELTS Writing Task 2 essay responds to its question. Don't score it and
don't give general feedback.
Return JSON:
{"parts": [{"id": "...", "addressed": "fully|partly|no", "evidence_quote": "..."}],
 "position": {"stated_in_intro": bool, "stated_in_conclusion": bool,
              "consistent_throughout": bool, "position_quote": "..."},
 "main_ideas": [{"idea": "...", "developed": bool, "has_example": bool, "quote": "..."}]}
Definitions:
- parts: one entry per required part given below, same ids.
  "fully" = the part is dealt with and supported with reasons or examples.
  "partly" = mentioned but not developed with reasons or support.
  "no" = not dealt with; evidence_quote is then "".
- developed = the idea is explained with at least one reason or consequence beyond
  restating it.
- has_example = a specific example, case or data point supports it (not a generic claim).
- If the question doesn't require a position, set position fields to false and
  position_quote to "".
Every quote must be verbatim from the essay, max 30 words.
---USER---
Question: $prompt_text
Required parts: $parts_json
Essay:
$essay_text
```

### 6.3 P3 — `judge` (the band judgment)

```
You are an IELTS Writing Task 2 examiner. Score strictly against the official band
descriptors below.

$rubric_text
$fewshot_block
Rules:
- Score each criterion as a WHOLE band from 0 to 9. Never use half bands.
- Don't compute an overall band.
- If a MEASURED EVIDENCE block is given, its numbers were computed by software and are
  reliable counts. Where your impression conflicts with them, trust the counts and explain.
- For each criterion: name the descriptor phrase that best matches, quote essay text that
  shows it, and state what prevents the next band up.
- Awarding 8 or 9 requires at least two verbatim quotes matching the band 8/9 descriptor
  language. Otherwise award 7 at most.
- Feedback must reference this essay specifically. No generic praise.
Return JSON matching this schema: $schema_json
---USER---
Question: $prompt_text
Word count: $word_count$underlength_note
$evidence_block
Essay:
$essay_text
```

Variables built in code:
- `$rubric_text`: contents of `rubric/task2_band_descriptors.md`.
- `$schema_json`: `EssayJudgment.model_json_schema()` as JSON.
- `$underlength_note`: `" (under 250 words)"` or `""`.
- `$fewshot_block`: `""` when off. Otherwise:
  ```
  EXAMPLES — essays with bands given by official IELTS examiners:
  Example 1
  Question: ...
  Essay:
  ...
  Official bands: TR 6, CC 7, LR 6, GRA 6        (or "Official overall band: 6.5" if criteria weren't published)

  ```
- `$evidence_block`: `""` when `evidence=False`. Otherwise it is rendered by
  `scoring/evidence.py`: one line per group, a group is omitted if none of its features
  exist yet, and any `null` renders as `n/a`. Percentages have no decimals, rates have one.
  ```

  MEASURED EVIDENCE
  Grammar: error-free sentences 62%; grammar/punctuation errors per 100 words 3.1; complex sentences 45%; clause types relative 3, adverbial 2, conditional 1, passive 2; sample errors: "<sentence>" — <message>; ...
  Lexis: rare-word share 18%; spelling errors per 100 words 0.8; prompt-copying 12%; most repeated: society 7, people 6, ...
  Cohesion: 4 paragraphs (45, 110, 98, 40 words); linkers per 100 words 4.2 (9 distinct; 30% of sentences start with one)
  Task: parts addressed p1 fully, p2 partly; position in intro yes, in conclusion yes, consistent yes; main ideas developed 3/4, with examples 2/4
  ```
  Later features (§4.4) each add their own clause to the matching line when they're built.

### 6.4 Later prompts (tasks L2, L3)

P4 — `collocations`:
```
You judge word combinations written by English learners. For each item, decide whether
the combination is natural in formal written English, in its sentence context.
Labels: "natural", "unnatural", "uncertain". For "unnatural", give the most natural fix.
Judge ONLY the combination, not grammar elsewhere in the sentence.
Return JSON: {"items": [{"id": "...", "label": "...", "fix": "... or empty"}]}
---USER---
Items:
$candidates_json
```

P5 — `paragraph_ideas`:
```
For each paragraph of an essay, state its central idea in one short sentence, and say
whether the paragraph keeps to a single central idea.
Introductions and conclusions count as having a single central idea if they only
introduce or summarise.
Return JSON: {"paragraphs": [{"index": 0, "central_idea": "...", "has_single_central_idea": bool}]}
---USER---
Paragraphs:
$numbered_paragraphs
```

## 7. Band math, confidence and display (`scoring/bands.py`)

```python
import math
from typing import Literal

SUGGESTIVE_FROM = 8   # single source of truth

def round_writing_band(mean: float) -> float:
    return math.floor(mean * 2) / 2        # round DOWN to the nearest 0.5

def criterion_confidence(band: int) -> Literal["scored", "suggestive"]:
    return "suggestive" if band >= SUGGESTIVE_FROM else "scored"

def overall_confidence(bands: list[int], overall: float) -> Literal["scored", "partial", "suggestive"]:
    if overall >= SUGGESTIVE_FROM:
        return "suggestive"
    if any(b >= SUGGESTIVE_FROM for b in bands):
        return "partial"
    return "scored"

def display_headline(overall: float, confidence: str) -> str:
    if confidence == "suggestive":
        return f"7.5+ (model suggests {overall:.1f})"
    return f"{overall:.1f}"
```

- overall = `round_writing_band((TR + CC + LR + GRA) / 4)`.
- Examples: 7,7,6,6 → 6.5 · 7,7,7,6 → 6.75 → 6.5 · 8,7,7,7 → 7.25 → 7.0 · 8,8,8,8 → 8.0.
- Round-down is the commonly cited rule and hasn't been verified (open question §10.3). It
  lives in one function so changing it is a one-line fix.
- This is an *estimated Task 2 band*. An official Writing score also weights in Task 1.

**UI display:**

| Case | Shown |
|---|---|
| Criterion 0-7 | `7` |
| Criterion 8-9 | `8 · suggestive`, tooltip: "The model rated this 8+. Cheap models can't reliably tell 7, 8 and 9 apart. Read as *at least 7, possibly higher*. Confirm with an examiner or a trusted marker." |
| Overall `scored` | `display_headline`, e.g. `6.5` |
| Overall `partial` | `7.5`, plus the note "includes suggestive criteria (LR)" |
| Overall `suggestive` | `7.5+ (model suggests 8.0)` |
| `underlength` | "Under 250 words" warning |
| `rejected` / `too_short` | The band plus the reason, with no criterion feedback |

## 8. Schemas

### 8.1 LLM responses (`scoring/schemas.py`, pydantic)

```python
from typing import Annotated, Literal
from pydantic import BaseModel, Field

Band = Annotated[int, Field(ge=0, le=9)]

class CriterionJudgment(BaseModel):
    band: Band
    descriptor_match: str
    feedback: str
    quoted_issues: list[str]        # verbatim excerpts
    next_band_blocker: str          # "n/a" at 9

class EssayJudgment(BaseModel):     # P3 — no overall_band, on purpose
    task_response: CriterionJudgment
    coherence_cohesion: CriterionJudgment
    lexical_resource: CriterionJudgment
    grammatical_range_accuracy: CriterionJudgment
    summary: str

class Part(BaseModel):
    id: str
    requirement: str

class TaskParts(BaseModel):         # P1
    parts: list[Part] = Field(min_length=1, max_length=5)

class PartCoverage(BaseModel):
    id: str
    addressed: Literal["fully", "partly", "no"]
    evidence_quote: str

class Position(BaseModel):
    stated_in_intro: bool
    stated_in_conclusion: bool
    consistent_throughout: bool
    position_quote: str

class MainIdea(BaseModel):
    idea: str
    developed: bool
    has_example: bool
    quote: str

class TaskAnalysis(BaseModel):      # P2
    parts: list[PartCoverage]
    position: Position
    main_ideas: list[MainIdea]
```

### 8.2 Stored result (the `results.result` JSONB and the evaluator's `runs.jsonl` rows)

```json
{
  "status": "scored",
  "criteria": {
    "task_response": {
      "band": 7, "confidence": "scored",
      "descriptor_match": "...", "feedback": "...",
      "quoted_issues": ["..."], "quotes_verified": [true],
      "next_band_blocker": "..."
    },
    "coherence_cohesion": {}, "lexical_resource": {}, "grammatical_range_accuracy": {}
  },
  "summary": "...",
  "overall_band": 7.0,
  "overall_confidence": "partial",
  "display_headline": "7.0",
  "word_count": 287,
  "underlength": false,
  "message": "",
  "features": {"gra.error_free_sentence_ratio": 0.62},
  "checklist": {"tr.parts_addressed": []},
  "evidence": true,
  "fewshot_ids": [],
  "model": "openai/gpt-oss-120b",
  "temperature": 0,
  "prompt_versions": {"task_parts": "v1", "task_analysis": "v1", "judge": "v1"},
  "calls": [{"prompt": "judge", "version": "v1", "input_tokens": 0, "output_tokens": 0,
             "latency_ms": 0, "cached": false}],
  "stage_ms": {"precheck": 0, "features": 0, "checklist": 0, "judge": 0, "postprocess": 0}
}
```

- `rejected` / `too_short`: `criteria.*` holds only `{"band": n, "confidence": "scored"}`,
  `message` explains why, and `features`, `checklist` and `calls` are empty.
- `features` and `checklist` are `{}` when `evidence=false`.

## 9. LLM client (`scoring/llm.py`)

`call_json(prompt_name, version, variables, schema, cache_tag=None) -> (model_instance, call_meta)`

1. Load `worker/prompts/{prompt_name}.v{version}.txt`, split on `---USER---`, and fill both
   parts with `string.Template(...).substitute(variables)`. A missing variable raises.
2. `openai.OpenAI(base_url=LLM_BASE_URL, api_key=LLM_API_KEY)`, `model=LLM_MODEL`,
   `temperature=LLM_TEMPERATURE`, `response_format={"type": "json_object"}`. If the
   provider rejects `response_format`, retry once without it.
3. Validate with pydantic. On failure, make one repair call that appends the model's reply
   and the validation error and asks for corrected JSON. If that fails too, raise.
4. **Rate limit (HTTP 429):** if the response has a `Retry-After` header, sleep that long
   and retry once. Otherwise raise. Calls are sequential; no concurrency.
5. **Cache:** if `cache_tag` is not `None`, the key is
   `sha256(model, temperature, rendered system, rendered user, schema name, cache_tag)` and
   the file is `worker/.cache/llm/{key}.json`. A hit returns without a network call and
   with `cached=true`. The app passes `None`, except P1, which always uses `cache_tag="p1"`.
   The evaluator passes `"run{n}"`, so repeat runs stay independent but re-running an eval
   is free.
6. `call_meta = {prompt, version, model, input_tokens, output_tokens, latency_ms, cached}`.

```python
def quotes_verified(quotes: list[str], essay: str) -> list[bool]:
    norm = " ".join(essay.split()).lower()
    return [" ".join(q.split()).lower() in norm for q in quotes]
```

## 10. Open questions (need a decision before the related code is written)

1. **Non-English essays.** The rule is settled: the rubric's band 0 covers a response that
   "used a language other than English throughout". How to detect it is not: that needs a
   language-ID library (not in the deps) and a definition of "throughout". Until decided,
   only empty essays are `rejected`.
2. **Enforce the 8+ rule in code?** P3 says an 8 or 9 needs two verbatim quotes. Code
   could cap the band at 7 when fewer than 2 of that criterion's quotes pass
   `quotes_verified`. Not implemented until you decide.
3. **Overall rounding.** Round-down is unverified, and the band descriptors don't cover
   it. Confirm against another official source, or leave it and state the assumption in
   EVAL.md.
4. **Copied question text.** "Any copied rubric must be discounted" (TR band 1). Should
   the pre-check word count (§3) exclude text copied from the question? That needs a copy
   rule, e.g. which spans count as copied (`lr.prompt_overlap_ratio` measures 3-gram
   overlap but doesn't mark spans). Until decided, `word_count` includes copied text, and
   P3 sees `lr.prompt_overlap_ratio` in the evidence block.
5. **Rubric limiters as code caps or conflict flags.** The rubric's bold text marks
   "negative features that will limit a rating". Two of them match features we already
   measure:
   - "**Paragraphing may be inadequate or missing.**" (CC band 5) ↔ `cc.paragraph_count`
   - "**Subordinate clauses are rare and simple sentences predominate.**" (GRA band 4) ↔
     `gra.complex_sentence_ratio`

   The rubric gives no counts, so the feature values that trigger them need calibrating
   from the eval set (task L4). Decide then: a hard cap in code, or only a conflict flag.
