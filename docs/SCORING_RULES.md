# Scoring Rules — IELTS Writing Task 2 Scorer

This file replaces the scoring parts of `OVERVIEW.md` Phase 2 (the pydantic schema and
the "0-9 in 0.5 increments" rule).

## 1. Design principles

1. **Match real IELTS mechanics.** Examiners give each criterion a whole band. The
   half-band only shows up in the overall score, after the averaging and rounding.
2. **The LLM judges and the code calculates.** The model outputs the four criterion bands
   plus evidence. Code works out the overall band, the rounding and the confidence flags.
   It never trusts model arithmetic.
3. **Be honest about what a cheap model can do.** Bands 0-7 are the scorer's working
   range. Telling 7 from 8 from 9 depends on fine judgments ("rare errors", "skilful",
   "sophisticated control") that small or cheap models can't make reliably, and LLMs lean
   generous anyway. Any 8 or 9 is stored as given but shown as **suggestive**, not as a
   verdict.

## 2. Criterion bands

| Rule | Value |
|---|---|
| Criteria | Task Response (TR), Coherence & Cohesion (CC), Lexical Resource (LR), Grammatical Range & Accuracy (GRA) |
| Allowed values | Integers 0-9 only. No half bands per criterion. |
| Reliable range | 0-7 |
| Suggestive range | 8-9: flagged, never shown as a plain score |

### Deterministic pre-checks (in code, before any LLM call)

Check each rule against the official descriptor text you fetch in Phase 2 before you
hardcode it.

| Condition | Action |
|---|---|
| Empty essay / not English throughout | Don't call the LLM. All criteria = 0, status `rejected`. |
| 20 words or fewer | Don't call the LLM. All criteria = 1 (the public descriptors rate responses this short at Band 1). |
| Under 250 words | Call the LLM, pass `word_count` and `underlength=true` in the prompt, and show an "under 250 words" warning in the UI. There's no fixed deduction formula; TR judges it. |

Word count is always computed in code (split on whitespace) and passed to the model.
Models are bad at counting.

## 3. Overall band (computed in code)

```
mean    = (TR + CC + LR + GRA) / 4
overall = floor(mean * 2) / 2        # round DOWN to the nearest 0.5
```

Examples: 7,7,6,6 → 6.5 · 7,7,7,6 → 6.75 → **6.5** · 8,7,7,7 → 7.25 → **7.0**

> Round-down is the commonly cited rule for the Writing component. Keep it in one named
> function (`round_writing_band`) so it's a one-line change if you confirm otherwise.
> This is an *estimated Task 2 band*. An official Writing score also weights in Task 1.

## 4. Confidence flags

### Per criterion

| Band | `confidence` | UI display |
|---|---|---|
| 0-7 | `scored` | `7` |
| 8-9 | `suggestive` | `8 · suggestive`, with tooltip: "The model rated this 8+. Cheap models can't reliably tell 7, 8 and 9 apart. Read as *at least 7, possibly higher*. Confirm with an examiner or a trusted marker." |

### Overall

| Condition | `overall_confidence` | UI display |
|---|---|---|
| No criterion ≥ 8 | `scored` | `6.5` |
| At least one criterion ≥ 8, overall < 8.0 | `partial` | `7.5`, with a note: "includes suggestive criteria (LR)" |
| Overall ≥ 8.0 | `suggestive` | `8.0 · suggestive`, and the headline number becomes "7.5+" |

For overall `suggestive`, the UI headline shows **"7.5+ (model suggests 8.0)"** and not a
bare 8.0. That way the most prominent number is one the system can actually stand behind.

## 5. Prompt rules that support this

Add these to the system prompt, below the rubric text:

1. "Score each criterion as a **whole band from 0 to 9**. Never use half bands."
2. "For each criterion, name the band descriptor phrase that fits best and quote the essay
   text that shows it."
3. "For each criterion, state what stops the essay reaching the next band up
   (`next_band_blocker`). If you award 8 or 9, you must quote at least two essay passages
   matching the band 8/9 descriptor language. Otherwise award 7."
4. "Don't compute an overall band."

Rule 3 pushes back on the generosity bias: an 8+ has to be argued from evidence, not
handed out by default.

## 6. Schemas

### What the LLM returns

```python
from typing import Annotated
from pydantic import BaseModel, Field

Band = Annotated[int, Field(ge=0, le=9)]

class CriterionJudgment(BaseModel):
    band: Band
    descriptor_match: str          # the descriptor phrase it matched
    feedback: str                  # specific; references essay content
    quoted_issues: list[str]       # verbatim excerpts from the essay
    next_band_blocker: str         # what stops band+1 ("n/a" at 9)

class EssayJudgment(BaseModel):
    task_response: CriterionJudgment
    coherence_cohesion: CriterionJudgment
    lexical_resource: CriterionJudgment
    grammatical_range_accuracy: CriterionJudgment
    summary: str
    # note: no overall_band here, on purpose
```

### What the code builds and stores

```python
import math
from typing import Literal

SUGGESTIVE_FROM = 8   # single source of truth for the threshold

Confidence = Literal["scored", "suggestive"]
OverallConfidence = Literal["scored", "partial", "suggestive"]

def round_writing_band(mean: float) -> float:
    return math.floor(mean * 2) / 2

def criterion_confidence(band: int) -> Confidence:
    return "suggestive" if band >= SUGGESTIVE_FROM else "scored"

def overall_confidence(bands: list[int], overall: float) -> OverallConfidence:
    if overall >= SUGGESTIVE_FROM:
        return "suggestive"
    if any(b >= SUGGESTIVE_FROM for b in bands):
        return "partial"
    return "scored"

def quotes_verified(quotes: list[str], essay: str) -> list[bool]:
    norm = " ".join(essay.split()).lower()
    return [" ".join(q.split()).lower() in norm for q in quotes]
```

Stored result (JSONB in `results.criteria`, plus flat columns for querying):

```json
{
  "criteria": {
    "lexical_resource": {
      "band": 8, "confidence": "suggestive",
      "feedback": "...", "quoted_issues": ["..."], "quotes_verified": [true],
      "descriptor_match": "...", "next_band_blocker": "..."
    }
  },
  "overall_band": 7.0,
  "overall_confidence": "partial",
  "display_headline": "7.0",
  "word_count": 287,
  "underlength": false,
  "model": "deepseek-chat", "prompt_version": "v2", "temperature": 0
}
```

`results` table additions: `overall_band NUMERIC(2,1)`, `overall_confidence TEXT`,
`word_count INT`, `model TEXT`, `prompt_version TEXT`.

## 7. Eval changes (Phase 3)

Report the two ranges separately. One mixed accuracy number hides where the model fails.

| Metric | Computed on | Why |
|---|---|---|
| Mean absolute error per criterion | Essays whose **true** band is 0-7 | The headline accuracy claim covers only the range the system claims to handle |
| Run-to-run variance | All essays, 3-5 runs each | Flag any criterion whose band changes between runs |
| **Suggestive precision** | Runs where the model gave ≥ 8 | Of the 8+ ratings, how many had a true band ≥ 8? Shows whether the flag carries any signal |
| **False-8 rate** | Essays with true band ≤ 7 | How often the model inflates a 7 to 8+. This is the generosity bias, measured |
| Quote verification rate | All runs | Share of `quoted_issues` actually found in the essay (hallucination check) |

If suggestive precision turns out high on a stronger model, you can raise
`SUGGESTIVE_FROM` to 9 for that model only. That's why it's a single constant, and why
`model` is stored with every result.
