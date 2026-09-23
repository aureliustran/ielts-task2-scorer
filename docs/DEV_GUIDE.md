# Dev Guide — IELTS Task 2 Scorer

Hands-on build guide. Every stage writes to Postgres, Redis carries work and live status
between services, and files remain only for code, prompts and one seed backup.
Work top to bottom; each step ends with a **Check** to pass before moving on.

Related docs: `OVERVIEW.md` (spec), `SCORING_RULES.md` (bands, rounding, confidence flags).

---

## Part 0 — Infrastructure (~1 h)

### 0.1 Repo layout

```
ieltsTask2Scorer/
├── docker-compose.yml
├── .env                  # git-ignored
├── backend/              # Go + Gin
│   ├── cmd/api/main.go
│   ├── internal/{config,db,queue,handlers,consumer,metrics}/
│   └── migrations/       # goose SQL files
├── worker/               # Python
│   ├── main.py
│   ├── stages/{precheck,features,embed,llm_score,postprocess}.py
│   └── prompts/score_v1.md
├── frontend/             # React (Vite)
├── eval/
│   ├── seed/essays.csv   # the only data file: dataset backup
│   └── explore.ipynb     # read-only analysis via pd.read_sql
└── docs/
```

### 0.2 `docker-compose.yml`

```yaml
services:
  postgres:
    image: pgvector/pgvector:pg16
    environment: { POSTGRES_USER: ielts, POSTGRES_PASSWORD: ielts, POSTGRES_DB: ielts_scorer }
    ports: ["5432:5432"]
    volumes: [pgdata:/var/lib/postgresql/data]
  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]
  languagetool:
    image: erikvl87/languagetool
    ports: ["8010:8010"]
volumes: { pgdata: {} }
```

### 0.3 `.env`

```
DATABASE_URL=postgres://ielts:ielts@localhost:5432/ielts_scorer?sslmode=disable
REDIS_URL=redis://localhost:6379
LANGUAGETOOL_URL=http://localhost:8010
LLM_BASE_URL=https://api.deepseek.com/v1
LLM_API_KEY=...
LLM_MODEL=deepseek-chat
ADMIN_PASSWORD_HASH=$2a$10$...     # bcrypt hash, never the plaintext password
SESSION_SECRET=...
```

**Check:** `docker compose up -d` → `docker compose ps` shows 3 containers running, and
`http://localhost:8010/v2/languages` returns JSON.

---

## Part 1 — Database (~1–2 h)

### 1.1 Migrations with goose

Install: `go install github.com/pressly/goose/v3/cmd/goose@latest`.
Create `backend/migrations/00001_init.sql`:

```sql
-- +goose Up
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE essays (
  id          SERIAL PRIMARY KEY,
  origin      TEXT NOT NULL CHECK (origin IN ('user','eval')),
  prompt      TEXT NOT NULL,
  essay       TEXT NOT NULL,
  word_count  INT,
  -- human bands: only for eval essays
  tr SMALLINT, cc SMALLINT, lr SMALLINT, gra SMALLINT,
  source      TEXT CHECK (source IN ('public','own','synthetic')),
  split       TEXT CHECK (split IN ('dev','test')),
  embedding   vector(384),
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE scoring_config (
  version TEXT PRIMARY KEY, config JSONB NOT NULL, notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE eval_batches (
  id SERIAL PRIMARY KEY,
  condition TEXT NOT NULL,             -- 'A' | 'B' | 'C'
  model TEXT NOT NULL, prompt_version TEXT NOT NULL,
  config_version TEXT REFERENCES scoring_config(version),
  runs_per_essay SMALLINT DEFAULT 3,
  split TEXT DEFAULT 'dev',
  status TEXT DEFAULT 'running',
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE jobs (
  id SERIAL PRIMARY KEY,
  essay_id INT NOT NULL REFERENCES essays(id),
  type TEXT NOT NULL CHECK (type IN ('score','embed')),
  batch_id INT REFERENCES eval_batches(id),   -- NULL = normal user submission
  run_no SMALLINT,
  status TEXT NOT NULL DEFAULT 'pending'
         CHECK (status IN ('pending','processing','done','failed')),
  error TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ
);

CREATE TABLE stage_results (
  id BIGSERIAL PRIMARY KEY,
  job_id INT NOT NULL REFERENCES jobs(id),
  stage TEXT NOT NULL CHECK (stage IN ('precheck','features','embed','llm_score','postprocess')),
  status TEXT NOT NULL CHECK (status IN ('ok','failed','skipped')),
  output JSONB, error TEXT,
  tokens INT, latency_ms INT,
  started_at TIMESTAMPTZ, finished_at TIMESTAMPTZ,
  UNIQUE (job_id, stage)
);

CREATE TABLE annotations (
  essay_id INT REFERENCES essays(id),
  sentence_idx INT,
  sentence TEXT,
  error_free BOOLEAN,
  is_complex BOOLEAN,
  error_tags JSONB,           -- ["article","agreement"]
  PRIMARY KEY (essay_id, sentence_idx)
);

CREATE TABLE eval_metrics (
  batch_id INT REFERENCES eval_batches(id),
  criterion TEXT,
  qwk REAL, exact REAL, adjacent REAL, false8_rate REAL,
  PRIMARY KEY (batch_id, criterion)
);

CREATE INDEX ON jobs (batch_id);
CREATE INDEX ON stage_results (job_id);

-- +goose Down
DROP TABLE eval_metrics, annotations, stage_results, jobs, eval_batches, scoring_config, essays;
```

### 1.2 Metric views — `00002_views.sql`

```sql
-- +goose Up
CREATE VIEW eval_run_bands AS
SELECT j.batch_id, j.essay_id, j.run_no,
       (s.output->>'tr')::int  AS tr, (s.output->>'cc')::int  AS cc,
       (s.output->>'lr')::int  AS lr, (s.output->>'gra')::int AS gra
FROM jobs j JOIN stage_results s ON s.job_id = j.id AND s.stage = 'postprocess'
WHERE j.batch_id IS NOT NULL AND s.status = 'ok';

CREATE VIEW eval_variance AS
SELECT batch_id, essay_id,
       max(tr)-min(tr) AS tr_spread, max(cc)-min(cc) AS cc_spread,
       max(lr)-min(lr) AS lr_spread, max(gra)-min(gra) AS gra_spread
FROM eval_run_bands GROUP BY batch_id, essay_id;

CREATE VIEW stage_stats AS
SELECT stage, count(*) AS n,
       avg(latency_ms)::int AS avg_ms,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms) AS p95_ms,
       avg((status = 'failed')::int) AS fail_rate
FROM stage_results GROUP BY stage;

-- +goose Down
DROP VIEW stage_stats, eval_variance, eval_run_bands;
```

### 1.3 First config row

```sql
INSERT INTO scoring_config VALUES ('cfg-v1',
 '{"zipf_rare":4.0,"lt_lang":"en-GB","lt_skip":["STYLE","TYPOGRAPHY","REDUNDANCY"],
   "suggestive_from":8,"temperature":0}', 'first guess, untuned');
```

**Check:** `goose -dir backend/migrations postgres "$DATABASE_URL" up` succeeds, and `\dt`
in psql lists 7 tables.

---

## Part 2 — Message contracts (agree on these before writing service code)

### Redis keys

| Key | Type | Written by | Read by |
|---|---|---|---|
| `queue:jobs` | List | Gin (`LPUSH`) | Worker (`BRPOP`) |
| `stream:stage_events` | Stream, consumer group `gin` | Worker (`XADD`) | Gin (`XREADGROUP`) |
| `job:{id}` | Hash, TTL 1h | Gin | Gin (fast polling) |

### Job message (Gin → worker)

```json
{"job_id": 42, "type": "score", "essay_id": 7, "prompt": "...", "essay": "...",
 "condition": "B", "model": "deepseek-chat", "prompt_version": "v1",
 "config": {"zipf_rare": 4.0, "...": "..."},
 "few_shot": []}
```

Gin puts the whole config (and, for condition C, the few-shot examples) in the message,
so the worker never reads Postgres.

### Stage event (worker → Gin), one per stage plus a final event

```json
{"job_id": 42, "stage": "features", "status": "ok",
 "output": "{...json string...}", "tokens": 0, "latency_ms": 180,
 "started_at": "...", "finished_at": "...", "error": ""}
```

The final event uses `stage: "_done"` or `"_failed"`, which marks the job complete.

---

## Part 3 — Go backend (~1 day)

Dependencies: `github.com/gin-gonic/gin`, `github.com/jackc/pgx/v5/pgxpool`,
`github.com/redis/go-redis/v9`, `golang.org/x/crypto/bcrypt`.

### 3.1 Endpoints

| Method | Path | What it does |
|---|---|---|
| POST | `/login` | Check the password against the bcrypt hash; set a signed cookie |
| POST | `/essays` | Insert essay (`origin='user'`), insert job, `LPUSH`; return `job_id` |
| GET | `/jobs/:id` | Read `job:{id}` from Redis; fall back to Postgres (job + stage_results) |
| GET | `/essays/:id/similar` | pgvector nearest neighbours |
| POST | `/admin/essays/import` | Bulk-insert eval essays from the seed CSV; enqueue `embed` jobs |
| POST | `/eval/batches` | Create a batch; one job per essay × run; `LPUSH` each |
| GET | `/eval/batches/:id` | Progress: counts by job status |
| POST | `/eval/batches/:id/metrics` | Compute QWK etc.; write to `eval_metrics` |

### 3.2 Consumer goroutine — the heart of the tracing

```go
func RunConsumer(ctx context.Context, rdb *redis.Client, db *pgxpool.Pool) {
    rdb.XGroupCreateMkStream(ctx, "stream:stage_events", "gin", "0") // ignore "exists" error
    for {
        res, err := rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
            Group: "gin", Consumer: "api-1",
            Streams: []string{"stream:stage_events", ">"},
            Count: 50, Block: 5 * time.Second,
        }).Result()
        if err == redis.Nil { continue }
        if err != nil { log.Println(err); time.Sleep(time.Second); continue }

        for _, msg := range res[0].Messages {
            if err := persistEvent(ctx, db, rdb, msg.Values); err != nil {
                log.Println("persist:", err)
                continue // not ACKed → stays pending, can be reprocessed
            }
            rdb.XAck(ctx, "stream:stage_events", "gin", msg.ID)
        }
    }
}
```

In `persistEvent`:

- Normal stage: `INSERT INTO stage_results ... ON CONFLICT (job_id, stage) DO UPDATE ...`
  (replays are safe), then `HSET job:{id} stage <stage> status processing` and `EXPIRE` 1h.
- `_done`: `UPDATE jobs SET status='done', completed_at=now()`. For an `embed` job, also
  `UPDATE essays SET embedding = $1::vector`, passing the text form `"[0.1,0.2,...]"`.
- `_failed`: set the job to `failed` and save the error.

**ACK only after the database commit.** That's how the design avoids losing events.

### 3.3 Timeout sweeper (second goroutine, every 30 s)

```sql
UPDATE jobs SET status='failed', error='timeout'
WHERE status IN ('pending','processing') AND created_at < now() - interval '3 minutes';
```

### 3.4 Creating a batch

```sql
INSERT INTO jobs (essay_id, type, batch_id, run_no)
SELECT e.id, 'score', $1, r
FROM essays e CROSS JOIN generate_series(1, $2) r
WHERE e.origin='eval' AND e.split=$3 AND e.source <> 'synthetic'
RETURNING id, essay_id;
```

Then `LPUSH` one message per returned row, in a Redis pipeline (one round trip).

**Check:** `curl -X POST /essays` returns a `job_id`, and `redis-cli LRANGE queue:jobs 0 -1`
shows the message.

---

## Part 4 — Python worker, stubbed (~½ day) — proves Phase 1

Dependencies: `pip install redis pydantic python-dotenv`

### 4.1 `worker/main.py`

```python
import json, time, os, traceback, datetime as dt
import redis
from stages import precheck, features, embed, llm_score, postprocess

r = redis.from_url(os.environ["REDIS_URL"], decode_responses=True)
now = lambda: dt.datetime.now(dt.timezone.utc).isoformat()

def emit(job_id, stage, status, output=None, tokens=0, ms=0, started=None, error=None):
    r.xadd("stream:stage_events", {
        "job_id": job_id, "stage": stage, "status": status,
        "output": json.dumps(output or {}), "tokens": tokens, "latency_ms": ms,
        "started_at": started or now(), "finished_at": now(), "error": error or "",
    })

def run_stage(job, name, fn, *args):
    t0, started = time.perf_counter(), now()
    out, tokens = fn(*args)                       # each stage returns (output_dict, tokens)
    emit(job["job_id"], name, "ok", out, tokens, int((time.perf_counter()-t0)*1000), started)
    return out

def score_pipeline(j):
    pre = run_stage(j, "precheck", precheck.run, j["essay"])
    if pre["short_circuit"]:                      # empty or ≤20 words: no LLM call
        return run_stage(j, "postprocess", postprocess.from_precheck, pre)
    feats = run_stage(j, "features", features.run, j["essay"], j["config"]) \
            if j["condition"] in ("B", "C") else None
    judg = run_stage(j, "llm_score", llm_score.run, j, pre, feats)
    return run_stage(j, "postprocess", postprocess.run, judg, pre, j["essay"], j["config"])

PIPELINES = {
    "embed": lambda j: run_stage(j, "embed", embed.run, j["essay"]),
    "score": score_pipeline,
}

while True:
    _, raw = r.brpop("queue:jobs")
    job = json.loads(raw)
    try:
        final = PIPELINES[job["type"]](job)
        emit(job["job_id"], "_done", "ok", final)
    except Exception as e:
        emit(job["job_id"], "_failed", "failed", error=f"{e}\n{traceback.format_exc()[-800:]}")
```

### 4.2 Stubs first

Every stage starts as a stub, e.g. `llm_score.run` returns
`({"tr":6,"cc":6,"lr":6,"gra":6}, 0)`.

### 4.3 React

A textarea, a submit button, and polling `GET /jobs/:id` every 2 s, showing stage names as
they complete (doubles as a progress indicator).

**Check (Phase 1 done):** submit from React and watch the stages tick by. Then:

```sql
SELECT stage, status, latency_ms FROM stage_results WHERE job_id = <id> ORDER BY id;
```

shows all 4 stages. Stop Gin mid-job and restart it: events are processed after the
restart, nothing lost.

---

## Part 5 — Seed data and embeddings (~½ day)

### 5.1 Seed CSV

`eval/seed/essays.csv`: `prompt, essay, tr, cc, lr, gra, source, split`. Add the 3
synthetic practice essays as `source=synthetic`, plus real marked essays as you collect
them. Set `split` once and never change it.

### 5.2 `stages/embed.py`

```python
from sentence_transformers import SentenceTransformer
_m = SentenceTransformer("all-MiniLM-L6-v2")      # 384 dims; fixed forever
def run(essay):
    v = _m.encode(essay, normalize_embeddings=True).tolist()
    return {"embedding": v}, 0
```

Also add embedding to the user `score` pipeline so similarity search works for real
submissions.

### 5.3 Import

Upload the CSV to `POST /admin/essays/import`. Gin inserts rows and enqueues one `embed`
job per essay.

**Check:**

```sql
SELECT count(*) FILTER (WHERE embedding IS NOT NULL), count(*) FROM essays WHERE origin='eval';
```

Both numbers match.

### 5.4 Leakage check

```sql
SELECT t.id, d.id, t.embedding <=> d.embedding AS dist
FROM essays t JOIN essays d ON d.split='dev'
WHERE t.split='test' AND t.embedding <=> d.embedding < 0.1;
```

Should return no rows. Any pair returned: remove one side from its split.

---

## Part 6 — Hand annotation and features (~1 day)

### 6.1 Hand annotation, stored in the database

Take the 3 synthetic essays plus 2 real `dev` essays. A small script splits each into
sentences with spaCy and inserts rows into `annotations` with `error_free` and
`is_complex` left NULL. Fill those in yourself in DBeaver or psql.

### 6.2 `stages/features.py`

Feature functions: accuracy (LanguageTool error-free sentence ratio, errors/100 words),
complexity (spaCy clause labels), lexis (MTLD, Zipf rare-word share), collocations
(spaCy dependency pairs), cohesion (linker lexicon, paragraphs). Two rules:

- Read thresholds from `config` (e.g. `config["zipf_rare"]`), never constants.
- `run()` returns one flat dict plus `config_version`.

### 6.3 Check code vs hand marking, in SQL

```sql
SELECT a.essay_id,
       avg(a.error_free::int)                 AS hand_error_free,
       (s.output->>'error_free_ratio')::float AS code_error_free
FROM annotations a
JOIN jobs j ON j.essay_id = a.essay_id
JOIN stage_results s ON s.job_id = j.id AND s.stage='features'
GROUP BY a.essay_id, s.output;
```

Tune `lt_skip` and `zipf_rare` until the values are close. **Each tuning round is a new
`scoring_config` row** (`cfg-v2`, `cfg-v3`, …), never an edit.

### 6.4 Correlation with human bands (dev split only)

```python
df = pd.read_sql("""
  SELECT e.tr, e.cc, e.lr, e.gra, s.output AS f
  FROM essays e JOIN jobs j ON j.essay_id=e.id
  JOIN stage_results s ON s.job_id=j.id AND s.stage='features'
  WHERE e.split='dev' AND e.source <> 'synthetic'""", engine)
feats = pd.json_normalize(df.f); df = pd.concat([df.drop(columns="f"), feats], axis=1)
```

Spearman + boxplots per feature vs band. Keep features with |rho| ≥ 0.4. Save chosen
thresholds as a new `scoring_config` row with `notes` explaining them.

**Check:** the synthetic essays rank A < B < C on `error_free_ratio`, `mtld`, `rare_ratio`.

---

## Part 7 — Real LLM scoring (~1 day)

### 7.1 Prompt files

`worker/prompts/score_v1.md`: fetched rubric text + rules from `SCORING_RULES.md`. Each
change is a new file (`score_v2.md`); `prompt_version` refers to the filename.

### 7.2 `stages/llm_score.py`

- `openai` package with `base_url` from `.env` (any OpenAI-compatible provider).
- Condition decides the prompt: A = rubric + essay; B = + features block; C = B + 2
  few-shot examples.
- For C, Gin runs the pgvector nearest-neighbour query when creating the batch and puts
  the examples in `few_shot` in the job message.
- Validate with pydantic `EssayJudgment`; on failure retry once with the validation error
  included. Return `(judgment_dict, usage.total_tokens)`.

### 7.3 `stages/postprocess.py`

Overall band (round down), confidence flags (`scored`/`partial`/`suggestive`), quote
verification — per `SCORING_RULES.md`.

**Check:** submit essay C 3 times. All 3 jobs show `llm_score` with nonzero `tokens`, and
`postprocess` has `quotes_verified` filled.

---

## Part 8 — Running the benchmark (~1 day)

### 8.1 Create batches

```bash
curl -X POST localhost:8080/eval/batches -d '{"condition":"A","model":"deepseek-chat","prompt_version":"v1","config_version":"cfg-v3","runs_per_essay":3,"split":"dev"}'
# repeat for B and C
```

Watch progress with `GET /eval/batches/:id`.

### 8.2 Metrics endpoint — QWK in Go (~40 lines)

1. Observed matrix `O[i][j]`: count of (human = i, model = j) over 0–9.
2. Expected matrix `E[i][j] = rowSum[i] * colSum[j] / N`.
3. Weights `W[i][j] = (i - j)² / 81`.
4. `QWK = 1 − Σ(W·O) / Σ(W·E)`.

Model score per essay = median band across runs. Write QWK, exact, ±1 and false-8 rate
to `eval_metrics`.

### 8.3 Compare conditions

```sql
SELECT b.condition, m.criterion, m.qwk, m.exact, m.adjacent, m.false8_rate
FROM eval_metrics m JOIN eval_batches b ON b.id = m.batch_id
ORDER BY m.criterion, b.condition;

SELECT b.condition, avg(v.lr_spread) AS avg_lr_spread
FROM eval_variance v JOIN eval_batches b ON b.id = v.batch_id
GROUP BY b.condition;
```

### 8.4 Final test run

Choose the best condition from `dev`. Create **one** batch with `"split":"test"`. Its
metrics are the headline numbers.

**Check:** every number in `EVAL.md` comes from these queries and traces to a `batch_id`.

---

## Part 9 — Phase 4 extras (mostly free now)

- Token/latency logging: `SELECT * FROM stage_stats;`
- Essay history: `SELECT ... FROM essays WHERE origin='user' ORDER BY created_at DESC`
- "Similar essays you've submitted": `/essays/:id/similar` with `WHERE origin='user'`
- Error states: `jobs.status='failed'` + `jobs.error`

---

## Rules to keep throughout

1. **Go is the only service that writes to Postgres.** The worker only reports events to Redis.
2. **ACK a stream event only after the database commit.** Use upserts so replays are harmless.
3. **Never edit a config row or prompt file after using it.** Create a new version.
4. **The test split is used once**, at the end.
5. **Keep `eval/seed/essays.csv` up to date in git** — the backup for everything that took effort to collect.
