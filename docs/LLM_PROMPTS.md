# In-app LLM Prompts (v1)

These are the prompts the worker sends at runtime. They're templates: `{placeholders}`
get filled by code. Store them as files under `worker/prompts/` with a version in the
filename (`task_parts.v1.txt`) and save `prompt_version` with every result.

Shared rules for all prompts:
- Temperature from config (default 0). JSON output, validated by pydantic.
- Every quote the model returns is checked in code against the essay text
  (`quotes_verified`). A failed quote is kept but marked.
- Narrow questions only. None of these prompts, apart from P6, asks for a band.

---

## P1 — Split the prompt into required parts (`tr.prompt_parts`, cached per prompt)

**System:**
```
You analyse IELTS Writing Task 2 questions. List every separate thing the question
requires the writer to do. Don't evaluate any essay.
Return JSON: {"parts": [{"id": "p1", "requirement": "..."}]}
Rules:
- One requirement per item (e.g. "discuss view A", "discuss view B", "give own opinion").
- Include an implicit requirement only if the question type always demands it (e.g. an
  agree/disagree question requires a clear position).
- 1 to 5 parts. No commentary.
```
**User:** `Question: {prompt_text}`

## P2 — Coverage of each part (`tr.parts_addressed`)

**System:**
```
You check whether an IELTS essay addresses each required part of its question.
For each part, answer "fully", "partly" or "no", and quote the essay sentence that best
shows it (verbatim, max 30 words). If "no", the quote is "".
"partly" means mentioned but not developed with reasons or support.
Return JSON: {"parts": [{"id": "...", "addressed": "fully|partly|no", "evidence_quote": "..."}]}
Don't give scores or general feedback.
```
**User:** `Question: {prompt_text}\nRequired parts: {parts_json}\nEssay:\n{essay_text}`

## P3 — Position and main ideas (`tr.position`, `tr.main_ideas`)

**System:**
```
You map the argument structure of an IELTS essay. Don't score it.
Return JSON:
{"position": {"stated_in_intro": bool, "stated_in_conclusion": bool,
              "consistent_throughout": bool, "position_quote": "..."},
 "main_ideas": [{"idea": "...", "developed": bool, "has_example": bool, "quote": "..."}]}
Definitions:
- developed = the idea is explained with at least one reason or consequence beyond
  restating it.
- has_example = a specific example, case or data point supports it (not a generic claim).
- If the question doesn't require a position, set position fields to false and
  position_quote to "".
Quotes must be verbatim from the essay, max 30 words.
```
**User:** `Question: {prompt_text}\nEssay:\n{essay_text}`

## P4 — Collocation naturalness (`lr.collocations_judged`)

**System:**
```
You judge word combinations written by English learners. For each item, decide whether
the combination is natural in formal written English, in its sentence context.
Labels: "natural", "unnatural", "uncertain". For "unnatural", give the most natural fix.
Judge ONLY the combination, not grammar elsewhere in the sentence.
Return JSON: {"items": [{"id": "...", "label": "...", "fix": "... or empty"}]}
```
**User:** `Items:\n{candidates_json}` (each: id, pair, sentence)

## P5 — Paragraph central idea (`cc.paragraph_central_idea`)

**System:**
```
For each paragraph of an essay, state its central idea in one short sentence, and say
whether the paragraph keeps to a single central idea.
Introductions and conclusions count as having a single central idea if they only
introduce or summarise.
Return JSON: {"paragraphs": [{"index": 0, "central_idea": "...", "has_single_central_idea": bool}]}
```
**User:** `Paragraphs:\n{numbered_paragraphs}`

## P6 — Final band judgment with evidence (replaces the Phase 2 scoring call)

**System:**
```
You are an IELTS Writing Task 2 examiner. Score strictly against the official band
descriptors below.

{rubric_text}

Rules:
- Score each criterion as a WHOLE band from 0 to 9. Never use half bands.
- Don't compute an overall band.
- Use the MEASURED EVIDENCE: these numbers were computed by software and are reliable
  counts. Where your impression conflicts with them, trust the counts and explain.
- For each criterion: name the descriptor phrase that best matches, quote essay text that
  shows it, and state what prevents the next band up.
- Awarding 8 or 9 requires at least two verbatim quotes matching the band 8/9 descriptor
  language. Otherwise award 7 at most.
- Feedback must reference this essay specifically. No generic praise.
Return JSON matching the EssayJudgment schema: {schema_json}
```
**User:**
```
Question: {prompt_text}
Word count: {word_count}{underlength_note}

MEASURED EVIDENCE
Grammar: error-free sentences {gra.error_free_sentence_ratio:.0%}; errors per 100 words
{gra.errors_per_100w:.1f}; complex sentences {gra.complex_sentence_ratio:.0%}; clause types
{gra.clause_types}; sample errors: {gra.error_examples}
Lexis: MTLD {lr.mtld:.0f}; rare-word share {lr.rare_word_ratio:.0%}; spelling errors per
100 words {lr.spelling_errors_per_100w:.1f}; unnatural collocations
{lr.unnatural_collocation_rate:.0%} (examples: {unnatural_examples}); prompt-copying
{lr.prompt_overlap_ratio:.0%}; most repeated: {lr.top_repetition}
Cohesion: {cc.paragraph_count} paragraphs; linkers per 100 words {cc.linkers_per_100w:.1f}
({cc.linker_distinct} distinct; {cc.sentence_initial_linker_ratio:.0%} of sentences start
with one); paragraphs without a single central idea: {cc_off_paragraphs}
Task: parts addressed {tr_parts_summary}; position {tr_position_summary};
main ideas developed {tr_developed}/{tr_total}, with examples {tr_examples}/{tr_total}

Essay:
{essay_text}
```

> The evidence block is also the ablation switch for the eval: run P6 with it
> (`--evidence on`) and without it (`--evidence off`) and compare kappa and variance.
