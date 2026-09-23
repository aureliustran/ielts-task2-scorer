# Feature Definitions

This file defines what each measured feature is, how it's computed and what key it's
stored under. It's the contract between `worker/features/`, `worker/checklist/`, the
scoring prompt and the eval.

- **C** = computed deterministically in `features/`
- **J** = judged by the LLM in `checklist/` (narrow question, prompts in `LLM_PROMPTS.md`)
- **C+J** = code extracts the candidates, the LLM judges each one

**Thresholds:** none are defined here on purpose. Band cut-offs for any feature are
calibrated later from essays with known scores (`eval/calibrate.py`). Until then, features
are passed to the LLM as evidence and used in conflict flags only.

## 0. Shared preprocessing (`features/text.py`)
| Key | Definition |
|---|---|
| `word_count` | Whitespace-split tokens, excluding pure punctuation |
| `sentences` | spaCy sentence split (`en_core_web_sm`) |
| `paragraphs` | Split on one or more blank lines; strip empties |
| `content_lemmas` | Lemmas of NOUN/VERB/ADJ/ADV tokens, lowercased, stopwords removed |

## 1. Grammatical Range & Accuracy (`features/grammar.py`)
| Key | Type | Definition |
|---|---|---|
| `gra.error_free_sentence_ratio` | C | Share of sentences with zero LanguageTool matches in grammar or punctuation categories (spelling excluded, which counts under LR) |
| `gra.errors_per_100w` | C | LanguageTool grammar + punctuation matches ÷ word_count × 100 |
| `gra.complex_sentence_ratio` | C | Share of sentences containing ≥1 token with dep in {advcl, ccomp, relcl, acl, xcomp} or a subordinating `mark` |
| `gra.clause_types` | C | Counts: relative (`relcl`), adverbial (`advcl`), conditional (`mark` = "if"/"unless"), passive (`nsubjpass` or `auxpass`) |
| `gra.mean_sentence_length` | C | word_count ÷ number of sentences |
| `gra.clauses_per_sentence` | C | (finite verbs as clause heads) ÷ sentences |
| `gra.error_examples` | C | Up to 5 LanguageTool matches: {sentence, message, offset} |

## 2. Lexical Resource (`features/lexis.py`)
| Key | Type | Definition |
|---|---|---|
| `lr.mtld` | C | MTLD over lowercased word tokens (`lexicalrichness`) |
| `lr.rare_word_ratio` | C | Share of content lemmas with `wordfreq.zipf_frequency(w, "en") < 4.0` (outside roughly the most common few thousand words). The 4.0 is a measurement cut-off, not a band threshold |
| `lr.cefr_distribution` | C | Share of content lemmas per CEFR level A1–C2 (`cefrpy`), unknown kept separate |
| `lr.spelling_errors_per_100w` | C | LanguageTool TYPOS/spelling matches ÷ word_count × 100 |
| `lr.prompt_overlap_ratio` | C | Share of essay 3-grams that also appear in the prompt |
| `lr.top_repetition` | C | The 5 most frequent content lemmas with counts |
| `lr.collocation_candidates` | C | spaCy pairs: amod (ADJ+NOUN), dobj (VERB+NOUN), advmod (ADV+ADJ). Up to 30, deduplicated, with sentence context |
| `lr.collocations_judged` | J | Each candidate → {natural, unnatural, uncertain} + a suggested fix if unnatural |
| `lr.unnatural_collocation_rate` | C | unnatural ÷ judged (computed after J) |

## 3. Coherence & Cohesion (`features/cohesion.py`)
| Key | Type | Definition |
|---|---|---|
| `cc.paragraph_count` | C | len(paragraphs) |
| `cc.paragraph_word_counts` | C | Words per paragraph |
| `cc.linker_counts` | C | Counts by category (addition, contrast, cause_effect, example, sequence, conclusion) from `features/data/linkers.json` |
| `cc.linkers_per_100w` | C | Total linkers ÷ word_count × 100. **Not monotonic**: high values can mean mechanical overuse |
| `cc.linker_distinct` | C | Number of distinct linkers used |
| `cc.sentence_initial_linker_ratio` | C | Share of sentences that start with a linker (a sign of mechanical linking) |
| `cc.adjacent_similarity_mean` | C | Mean cosine similarity of adjacent sentence embeddings (`sentence-transformers/all-MiniLM-L6-v2`, the same local model used for pgvector) |
| `cc.paragraph_central_idea` | J | Per paragraph: {has_single_central_idea: bool, central_idea: str} |

## 4. Task Response (`checklist/task.py`)
| Key | Type | Definition |
|---|---|---|
| `tr.prompt_parts` | J | Prompt split into its required parts. Cached per prompt text hash |
| `tr.parts_addressed` | J | Per part: {addressed: fully / partly / no, evidence_quote} |
| `tr.position` | J | {stated_in_intro, stated_in_conclusion, consistent_throughout: bool, position_quote} |
| `tr.main_ideas` | J | List of {idea, developed: bool, has_example: bool, quote} |
| `tr.paragraph_relevance` | C | Cosine similarity of each paragraph embedding to the prompt embedding |
| `tr.underlength` | C | word_count < 250 |

## 5. Conflict flags (`scoring/conflicts.py`)
Once thresholds are calibrated, flag an LLM band that disagrees with the evidence, e.g.
GRA ≥ 8 while `gra.error_free_sentence_ratio` is low. Until calibration, only log the
feature values next to the band. No flags fire.

## 6. Storage
Everything above is stored as one JSON object in `results.features` (JSONB), with keys
exactly as written here.
