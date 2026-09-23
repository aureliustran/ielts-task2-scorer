# Evaluation — measuring the scorer

How the scorer is measured against official examiner bands. The code lives in
`evaluator/`. The findings go in `EVAL.md`, which the developer writes from the generated
reports.

## 1. What the eval set is, and isn't

- A list of IELTS Task 2 essays with **bands given by official IELTS examiners**. There are
  no other labels. Nobody on this project marks essays, and there are no self-marked or
  synthetic essays.
- It is **not training data.** Nothing is trained. The model sees an essay only inside one
  API call and never sees the essay's official band, except for the few-shot examples
  (§4), which are then excluded from every metric.
- Uses:
  1. **Accuracy:** the scorer's bands against the official ones.
  2. **Consistency:** the same essay scored several times.
  3. **Choosing versions:** prompts, evidence on/off, few-shot on/off, models.
  4. **Few-shot examples.**
  5. **Later, calibrating feature thresholds** (task L4).

## 2. File: `evaluator/data/essays.jsonl`

One JSON object per line:

```json
{"id": "cam17-t2-test1", "prompt": "...", "essay": "...",
 "overall": 6.5, "tr": 6, "cc": 7, "lr": 6, "gra": 6,
 "source": "Cambridge IELTS 17, Test 1", "published": "2022-05",
 "fewshot": false}
```

| Field | Rule |
|---|---|
| `id` | Unique, stable, never reused |
| `overall` | Official overall Task 2 band. **Required.** |
| `tr`, `cc`, `lr`, `gra` | Official criterion bands, or `null` if the source doesn't publish them |
| `source` | Book and test number, or page title plus URL |
| `published` | `YYYY-MM` (or `YYYY-01` if only the year is known) when the essay was first published |
| `fewshot` | `true` for the 1-2 essays used as few-shot examples |

Essays come only from official sources: the Cambridge IELTS books (examiner-marked sample
answers) and official IELTS / British Council / IDP pages.

**Copyright:** the book essays are copyrighted. If the repo is public, keep `essays.jsonl`
git-ignored and back it up elsewhere.

## 3. Splits: by publication date, not by hand

Every officially graded essay is published, so any of them may have been in the model's
training data. A model that has seen an essay next to its examiner comment can score it
from memory rather than judgment. This can't be avoided, so it gets measured instead:

- `--cutoff YYYY-MM` = the scoring model's training cutoff, taken from the provider's docs.
- **test** = essays with `published` after the cutoff. **dev** = everything else.
- The split therefore depends on the model. That's fine, because `model` is stored with
  every result.
- **Near-duplicates:** before any run, the evaluator embeds all essays (`EMBEDDING_MODEL`)
  and lists dev/test pairs with cosine distance < 0.1. The same essay reprinted in a newer
  book would otherwise be a contaminated "test" essay. It only warns; the developer fixes
  the data.
- **If there are no test essays** (nothing published after the cutoff), the report says so
  and EVAL.md must state that the accuracy may be inflated by memorisation.

## 4. Few-shot examples

- Only essays with `fewshot: true`. They must be in dev, have all four criterion bands, and
  are excluded from every metric in every condition, so conditions stay comparable.
- They are rendered into P3 as in `SCORING.md` §6.3.

## 5. Conditions and runs

| Flag | Values | Default |
|---|---|---|
| `--evidence` | `on`, `off`, `both` | `both` |
| `--fewshot` | `on`, `off`, `both` | `off` |
| `--runs` | N runs per essay per condition | 3 |
| `--split` | `dev`, `final` | `dev` |
| `--cutoff` | `YYYY-MM` | required |
| `--dry-run` | print the plan and cost estimate, call nothing | off |

- **Iterate on `--split dev` only, with 3 runs.** Change prompts and features, re-run,
  compare.
- **Once, at the end:** pick the best condition on dev and run `--split final --runs 5` with
  that condition. It scores dev and test and reports them side by side. This is the only
  run that touches test, and its numbers are the headline in EVAL.md.
- A lower score on test than on dev can mean contamination (the model memorised the older
  essays) or overfitting to dev (the prompts were tuned on it). The report can't tell them
  apart; EVAL.md should say so.
- Compare conditions **only within one model**. Cheap models are fine while iterating.

## 6. Metrics (`evaluator/metrics.py`)

The model's score per essay per condition = the **median** band across runs (criteria), and
`round_writing_band` of the median-band mean (overall).

| Metric | Computed on | Notes |
|---|---|---|
| MAE per criterion | Essays with that criterion published and true band 0-7 | The accuracy claim covers only the range the system claims to handle |
| Exact / adjacent (±1) agreement per criterion | Essays with that criterion published | |
| Quadratic weighted kappa per criterion | Same | `sklearn.metrics.cohen_kappa_score(weights="quadratic", labels=range(10))`. Reported, but don't draw conclusions while its interval is wide |
| Overall MAE and exact agreement | All scored essays | Every essay has `overall` |
| Run-to-run variation | All essays, all runs | Per essay × criterion: max − min band. Report the share with any change and list them |
| Suggestive precision | Runs where the model gave ≥ 8 | Share where the true band is ≥ 8 |
| False-8 rate | Essays with true band ≤ 7 | Share of runs rated ≥ 8: the generosity bias, measured |
| Quote verification rate | All runs | Share of quotes found by `quotes_verified`, reported separately for P3 and P2 |
| Feature correlation | dev only, `evidence=on` | Spearman (`scipy.stats.spearmanr`) of every numeric feature with the true criterion band, with n |

- **Every number is shown with its n**, and MAE, agreement and kappa also with a **95%
  bootstrap interval**: essays resampled with replacement, 1000 resamples, fixed seed,
  percentile method.
- With a small eval set the intervals will be wide. That is an honest result, not a bug.
- **No human-agreement baseline.** Nobody on the project marks essays. If IELTS publishes
  examiner-reliability figures for Writing, EVAL.md may cite them with the source. Never
  quote a figure from memory.

## 7. Cost controls

- **Calls per essay × run:**
  - `evidence=off`: 1 (P3).
  - `evidence=on`: P2 + P3, plus P1 once per distinct question (cached).
  - Later features L2 and L3 add P4 and P5.
- **LLM cache** (`SCORING.md` §9): each call is cached under its run number, so
  regenerating a report or resuming after a crash costs nothing.
- **`--dry-run`** prints the essays per split, the conditions, and the call count excluding
  cache hits. It also prints an estimated token total, using the mean tokens per prompt
  from the most recent `runs.jsonl`, or "unknown" if there's none yet.
- **Rate limits:** one retry on 429 honouring `Retry-After`. Calls are sequential.

## 8. Outputs

`evaluator/results/{YYYYMMDD-HHMMSS}/`:
- `config.json`: the command-line args, model, temperature, prompt versions and the list
  of essay ids per split.
- `runs.jsonl`: one line per essay × condition × run: `{essay_id, condition, run, result}`,
  where `result` is the stored result from `SCORING.md` §8.
- `report.md`: all §6 metrics, conditions side by side, dev and test side by side for
  `--split final`, the near-duplicate warnings, and token/latency totals per prompt.

Commit the result folders that EVAL.md cites. `worker/.cache/` is git-ignored.
