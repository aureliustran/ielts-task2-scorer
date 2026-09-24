# Spec — IELTS Writing Task 2 Scorer

What the system is and how its parts talk to each other. Scoring logic is in
`SCORING.md`, measuring it is in `EVALUATION.md`, the build order is in `TASKS.md`.

## 1. Goal

A local web app that scores an IELTS Writing Task 2 essay against the official band
descriptors: one whole band per criterion, an overall band computed in code, and specific
feedback that quotes the essay.

**Why it exists.** The developer (Aurelius, backend engineer, Go/Node.js) is building AI
engineering skills: prompt engineering, structured LLM output, embeddings, and above all a
real eval methodology instead of trusting a model's first answer. The Go/Python split is
deliberate practice in running a multi-service system. The eval result (how close the
scorer gets to official examiner bands, and how stable it is) is the most important output
of the project. UI polish is the least important.

**Timeline:** 3-5 days. Order of work is in `TASKS.md`: the scorer and its eval first, the
web stack after.

## 2. Non-goals

- No multi-user accounts or registration. One password gates the app.
- No production queue features (retries, dead-letter queues, backoff).
- **No training or fine-tuning.** The model's weights never change. The graded essays are
  an *eval set* used to measure the scorer, never "training data" (`EVALUATION.md` §1).
- No Task 1. No deployment; local only.
- No FastAPI. The worker only consumes Redis and exposes no HTTP API.

## 3. Architecture

```
client (React/Vite) --/api--> server (Go/Gin) --LPUSH queue:jobs--> worker (Python)
        ^                         |   ^                                   |
        |  poll GET /api/jobs/:id |   |  XREADGROUP stream:results        |  XADD stream:results
        +-------------------------+   +-----------------------------------+
                                  |
                           Postgres + pgvector        LanguageTool (worker only)
```

| Service | Folder | Owns |
|---|---|---|
| client | `client/` | UI. Talks only to the server, through `/api`. |
| server | `server/` | Auth, all Postgres reads/writes, job creation, result persistence. **The only service that touches Postgres.** |
| worker | `worker/` | Scoring pipeline, LLM calls, embeddings. Talks only to Redis, LanguageTool and the LLM provider. |
| evaluation | `evaluation/` | Offline eval; not a running service. Imports the worker's pipeline directly. Touches neither Redis nor Postgres. |

Infrastructure is in `docker-compose.yml`: Postgres (pgvector/pg16), Redis 7 and
LanguageTool (port 8010).

## 4. Configuration

One git-ignored `.env` per service, never one shared file. The `.env.example` next to each
is the list of keys. Add every new key there.

| File | Holds |
|---|---|
| `.env` (root) | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` only. Read by docker compose and by the server. |
| `server/.env` | `PORT`, `POSTGRES_HOST`, `POSTGRES_PORT`, `REDIS_URL`, `ADMIN_PASSWORD`, `SESSION_SECRET`, `JOB_TIMEOUT_SECONDS` |
| `worker/.env` | `REDIS_URL`, `LANGUAGETOOL_URL`, `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_MODEL`, `LLM_TEMPERATURE`, `EMBEDDING_MODEL`, `EMBEDDING_DIM`. No Postgres keys, on purpose. |
| `client/.env` | `VITE_API_URL`: the server address, used only as the Vite dev-proxy target. Never put a secret here; every `VITE_` var ends up in the browser bundle. |

The eval uses the worker's venv and `worker/.env`. It has no `.env` of its own.

**Server load order:** `godotenv.Load("../.env")` first, then `godotenv.Load(".env")`.
godotenv doesn't override variables that are already set, so the root file stays the
single source for the Postgres credentials. Build the URL in code:

```go
dbURL := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable",
    os.Getenv("POSTGRES_USER"), os.Getenv("POSTGRES_PASSWORD"),
    os.Getenv("POSTGRES_HOST"), os.Getenv("POSTGRES_PORT"), os.Getenv("POSTGRES_DB"))
```

## 5. Auth

- `ADMIN_PASSWORD` is plaintext in `server/.env` (git-ignored). On every startup the server
  bcrypt-hashes it and upserts the hash into the single-row `admin_credentials` table.
  Postgres never holds the plaintext. To rotate: change the value and restart.
- `POST /api/login {"password": "..."}` does a bcrypt compare against the stored hash. On
  success it sets a cookie `session=<expiry>.<HMAC-SHA256(expiry, SESSION_SECRET)>`
  (HttpOnly, SameSite=Lax, 7-day expiry). Every other `/api` route requires a valid cookie
  and returns 401 without one.
- `.env.example` files hold placeholders only (`changeme`), never a real password.

## 6. Redis contracts

| Key | Type | Written by | Read by |
|---|---|---|---|
| `queue:jobs` | List | server (`LPUSH`) | worker (`BRPOP`) |
| `job:{id}` | Hash, TTL 1 h | worker (`HSET stage <name>`) | server (progress for polling) |
| `stream:results` | Stream, consumer group `server` | worker (`XADD`) | server (`XREADGROUP`) |

**Job message** (server → worker, JSON string):
```json
{"job_id": 42, "essay_id": 7, "prompt": "...", "essay": "..."}
```
The worker scores with its default settings (`SCORING.md` §2). Eval conditions are chosen
in the eval, never through the queue.

**Result message** (worker → server, stream fields, all strings):
```
job_id     "42"
status     "done" | "failed"
result     stored-result JSON (SCORING.md §8), "" if failed
embedding  JSON array of EMBEDDING_DIM floats, "" if failed or the essay was rejected
error      "" or a message plus the last 800 chars of the traceback
```

**Worker loop** (`worker/main.py`): `BRPOP queue:jobs` → for each pipeline stage,
`HSET job:{id} stage <name>` and `EXPIRE job:{id} 3600` → run `scoring.pipeline.score` →
compute the embedding → `XADD stream:results`. Any exception: `XADD` with `status=failed`.
One job at a time.

## 7. Server behaviour

**Result consumer** (goroutine):
1. On startup, `XGROUP CREATE stream:results server 0 MKSTREAM` (ignore "already exists").
2. Read this consumer's pending messages first (ID `0`), then new ones (ID `>`), with
   `Count: 50, Block: 5s`.
3. Per message, in one transaction:
   `INSERT INTO results ... ON CONFLICT (job_id) DO NOTHING`, update the `jobs` row
   (status, error, completed_at), and `UPDATE essays SET embedding = $1::vector` (text form
   `[0.1,0.2,...]`) if an embedding is present.
4. `XACK` **only after commit**. A failed commit leaves the message pending for a retry, and
   the upsert makes replays harmless. A result that arrives after a timeout still wins.

**Timeout sweeper** (goroutine, every 30 s):
```sql
UPDATE jobs SET status='failed', error='timeout', completed_at=now()
WHERE status='pending' AND created_at < now() - make_interval(secs => $JOB_TIMEOUT_SECONDS);
```

**Job status.** `jobs.status` in Postgres is `pending | done | failed`. `GET /api/jobs/:id`
reports `processing` when the row is `pending` and `job:{id}` exists in Redis, and includes
its `stage`.

## 8. Postgres schema (`server/migrations/00001_init.sql`, goose)

```sql
-- +goose Up
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE admin_credentials (
  id            SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  password_hash TEXT NOT NULL,
  updated_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE essays (
  id         SERIAL PRIMARY KEY,
  prompt     TEXT NOT NULL,
  essay      TEXT NOT NULL,
  embedding  vector(384),            -- = EMBEDDING_DIM; all-MiniLM-L6-v2
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE jobs (
  id           SERIAL PRIMARY KEY,
  essay_id     INT NOT NULL REFERENCES essays(id),
  status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','failed')),
  error        TEXT,
  created_at   TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ
);

CREATE TABLE results (
  id                 SERIAL PRIMARY KEY,
  job_id             INT NOT NULL UNIQUE REFERENCES jobs(id),
  essay_id           INT NOT NULL REFERENCES essays(id),
  status             TEXT NOT NULL CHECK (status IN ('scored','rejected','too_short')),
  overall_band       NUMERIC(2,1) NOT NULL,
  overall_confidence TEXT NOT NULL,
  word_count         INT NOT NULL,
  model              TEXT,
  total_tokens       INT,
  latency_ms         INT,
  result             JSONB NOT NULL,   -- the full stored result, SCORING.md §8
  created_at         TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX ON jobs (essay_id);
CREATE INDEX ON results (essay_id);

-- +goose Down
DROP TABLE results, jobs, essays, admin_credentials;
```

The flat columns duplicate fields from `result` so they can be queried without JSON
operators. The eval set is not stored in Postgres (`EVALUATION.md` §2).

## 9. HTTP API (Gin, every route under `/api`)

| Method | Path | Does |
|---|---|---|
| POST | `/login` | §5. 204 plus cookie, or 401. |
| POST | `/essays` | Body `{prompt, essay}`. 400 if `prompt` is blank. The essay may be blank (the worker rejects it with a score). Inserts the essay and a `pending` job, then `LPUSH`es the job message. If the push fails, marks the job `failed` and returns 503. Returns `{essay_id, job_id}`. |
| GET | `/jobs/:id` | `{status: pending\|processing\|done\|failed, stage?, error?, result?}`. `result` is the JSONB, included when `done`. |
| GET | `/essays?limit=20` | History, newest first: `{id, created_at, prompt (first 120 chars), overall_band, overall_confidence}`. |
| GET | `/essays/:id` | The essay plus its latest result. |
| GET | `/essays/:id/similar?limit=5` | Nearest essays by cosine distance, excluding itself and rows with no embedding. |

Similarity query:
```sql
SELECT e.id, left(e.prompt, 120), e.created_at, r.overall_band,
       e.embedding <=> t.embedding AS distance
FROM essays e
JOIN essays t ON t.id = $1
LEFT JOIN LATERAL (SELECT overall_band FROM results WHERE essay_id = e.id
                   ORDER BY created_at DESC LIMIT 1) r ON true
WHERE e.id <> $1 AND e.embedding IS NOT NULL AND t.embedding IS NOT NULL
ORDER BY distance LIMIT $2;
```

Go dependencies: `gin-gonic/gin`, `jackc/pgx/v5/pgxpool`, `redis/go-redis/v9`,
`golang.org/x/crypto/bcrypt`, `joho/godotenv`. Migrations: `pressly/goose`.

## 10. Client

- All requests go to `/api/...`. `vite.config.ts` proxies `/api` to `VITE_API_URL`, so the
  cookie is same-origin and CORS isn't needed.
- **Screens:**
  - Login.
  - Submit: prompt textarea, essay textarea with a live word count.
  - Progress: polls `GET /api/jobs/:id` every 2 s and shows the current stage.
  - Result: headline, per-criterion band, feedback, quotes, summary, similar essays.
  - History.
- **Result display rules** are in `SCORING.md` §7: suggestive badges and tooltip, the
  headline string, the under-250-words warning. Quotes with `quotes_verified=false` are
  shown struck through with the label "not found in essay".
- **Error states:** failed job (show `error`), timeout, 401 (back to login), network error.
- Plain `fetch`, no state library. Pasted text only. PDF upload is a later task (`TASKS.md`).
