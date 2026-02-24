# Second Brain System Plan (v3)

## Context

Revision of the second brain plan (Forgejo issue #100), incorporating:

1. **Energy-efficient local AI**: Replace all Claude API calls with local Ollama inference (qwen2.5:3b on hawk). Add pgvector for semantic search (RAG). Zero ongoing API cost.
2. **GRAB system resilience patterns** ([Nate Jones](https://natesnewsletter.substack.com/p/grab-the-system-that-closes-open)): Confidence scoring (receipt), quality gate (bouncer), and fix button — the trust-building feedback loop that prevents second brain systems from dying.
3. **Per-bucket structured extraction**: Each bucket has its own schema. The LLM doesn't just classify — it extracts the pertinent fields for that bucket type. A `log` table keeps the full raw record with capture time and sequence.
4. **ntfy as capture conduit**: Mattermost was dropped (official image is amd64-only, incompatible with the all-ARM K8s cluster). ntfy handles both capture input and notification output — simpler, already deployed, and has native action buttons for the fix workflow.

## Architecture

```
                                              ┌──────────────────────────────┐
                                              │ hawk (Beelink SER5 Max)      │
                                              │ AMD Ryzen 7 6800U, 24GB RAM  │
                                              │                              │
                                              │  ┌─────────────┐             │
                                              │  │ Ollama      │             │
                                              │  │ (NixOS svc) │             │
                                              │  │ qwen2.5:3b  │             │
                                              │  │ nomic-embed  │             │
                                              │  └──────┬──────┘             │
                                              │         │ :11434             │
                                              └─────────┼────────────────────┘
                                                        │
┌─────────────┐     ┌──────────────────┐     ┌──────────┼────────────────────────────────┐
│ Phone/Desktop│────▶│ ntfy             │────▶│ n8n (4 workflows)                         │
│ (capture)    │     │ sb-capture topic │     │          │                                │
└─────────────┘     └──────────────────┘     │  classify/embed/summarize                 │
                                              │          │     ┌────────────────────┐      │
                                              │          └────▶│ pgvector           │      │
                                              │                │ (semantic search)  │      │
                                              │                └────────────────────┘      │
                                              │                                           │
                                              └──────────┬──────────┬─────────────────────┘
                                                         │          │
                              ┌───────────────────────────┤          │
                              ▼                          ▼          ▼
                     ┌────────────────┐          ┌───────────────────────┐
                     │ PostgreSQL     │          │ ntfy                  │
                     │ + pgvector     │          │ sb-digest  (receipts) │
                     │                │          │ sb-review  (low conf) │
                     │ log (master)   │          │ sb-daily   (digest)   │
                     │ people         │          │ sb-weekly  (recap)    │
                     │ ideas          │          └───────────────────────┘
                     │ projects       │
                     │ admin          │
                     └────────────────┘
```

## What Changes vs Original Plan

| Area | Original | v2 | v3 (current) |
|---|---|---|---|
| Capture conduit | Mattermost | Mattermost | **ntfy** (arm64 compatible) |
| Classification | Claude API | Ollama qwen2.5:3b | Ollama qwen2.5:3b |
| Daily digest | Claude API | Ollama qwen2.5:3b | Ollama qwen2.5:3b |
| Weekly recap | Claude API | Claude API | **Ollama qwen2.5:3b** |
| Embeddings | Not planned | nomic-embed-text | nomic-embed-text |
| Vector search | "Future enhancement" | pgvector | pgvector |
| Confidence scoring | Not planned | Core | Core |
| Quality gate | Not planned | Core | Core |
| Fix button | "Future enhancement" | Emoji reactions | **ntfy action buttons** |
| DB schema | 1 flat table | 5 tables | 5 tables |
| Monthly API cost | ~$0.60 | ~$0.02 | **$0.00** |
| Workflows | 3 | 4 | 4 |

## Components

### 1. ntfy (Capture Conduit + Notifications)

ntfy handles both sides: capture input (user publishes thoughts) and output (receipts, digests, fix buttons). Already deployed in step 1.

- Location: `kubernetes/base/apps/self-hosted/ntfy/`
- Image: `binwiederhier/ntfy`
- Resources: ~64MB RAM, 50m CPU
- Storage: 1Gi PVC (Longhorn, VolSync backup)
- Ingress: `ntfy.internal`
- Namespace: `self-hosted`

**Topics:**
| Topic | Purpose | Direction |
|---|---|---|
| `sb-capture` | User posts raw thoughts | Input |
| `sb-digest` | Receipts for high-confidence entries | Output |
| `sb-review` | Low-confidence entries with fix buttons | Output |
| `sb-daily` | Daily morning digest | Output |
| `sb-weekly` | Weekly Sunday recap | Output |

**Capture flow:** User sends a thought via the ntfy phone app (or `curl -d "thought" ntfy.internal/sb-capture`). n8n subscribes to `sb-capture` via ntfy's JSON subscription API (`/sb-capture/json`), processes the thought, and publishes the receipt back to `sb-digest` or `sb-review`.

**Fix button flow:** Low-confidence receipts posted to `sb-review` include ntfy action buttons (one per bucket). Tapping a button sends an HTTP request to an n8n webhook with the log entry ID and the correct bucket. ntfy's [action buttons](https://docs.ntfy.sh/publish/#action-buttons) support `http` actions natively.

Example receipt with fix buttons:
```bash
curl -H "Title: #42 Needs review (38%)" \
     -H "Tags: warning" \
     -H "Actions: http, People, https://n8n.internal/webhook/sb-fix?id=42&bucket=people; \
                  http, Ideas, https://n8n.internal/webhook/sb-fix?id=42&bucket=ideas; \
                  http, Projects, https://n8n.internal/webhook/sb-fix?id=42&bucket=projects; \
                  http, Admin, https://n8n.internal/webhook/sb-fix?id=42&bucket=admin" \
     -d "Talk to Sam about the thing" \
     ntfy.internal/sb-review
```

### 2. Second-Brain Database (CNPG PostgreSQL + pgvector)

Dedicated PostgreSQL cluster with per-bucket structured tables. The `log` table is the master record of every capture. Each bucket table stores only the fields pertinent to that bucket type, linked back to the log entry.

**CNPG Image:** `ghcr.io/cloudnative-pg/postgresql:16-bookworm` (standard bookworm images bundle pgvector)

**Schema:**

```sql
CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================
-- LOG: Master record of every capture. Full raw text, metadata,
-- embedding, and audit trail. Nothing is lost.
-- ============================================================
CREATE TABLE log (
    id              SERIAL PRIMARY KEY,
    seq             SERIAL,                       -- global capture sequence number
    raw_text        TEXT NOT NULL,                 -- original thought, verbatim
    bucket          VARCHAR(20) NOT NULL CHECK (bucket IN ('people', 'ideas', 'projects', 'admin')),
    confidence      REAL NOT NULL DEFAULT 0.0,     -- classification confidence 0.0-1.0
    needs_review    BOOLEAN DEFAULT FALSE,         -- bouncer flag
    embedding       vector(768),                   -- nomic-embed-text vector
    source_post_id  VARCHAR(100),                  -- ntfy message ID (for deduplication)
    created_at      TIMESTAMPTZ DEFAULT NOW(),     -- capture timestamp
    followed_up     BOOLEAN DEFAULT FALSE,
    follow_up_at    TIMESTAMPTZ
);

CREATE INDEX idx_log_bucket ON log(bucket);
CREATE INDEX idx_log_created ON log(created_at);
CREATE INDEX idx_log_followup ON log(followed_up, bucket);
CREATE INDEX idx_log_review ON log(needs_review) WHERE needs_review = TRUE;
CREATE INDEX idx_log_embedding ON log USING ivfflat (embedding vector_cosine_ops) WITH (lists = 20);

-- ============================================================
-- PEOPLE: Who you interacted with, relationship context, and
-- what to do about it.
-- ============================================================
CREATE TABLE people (
    id              SERIAL PRIMARY KEY,
    log_id          INTEGER NOT NULL REFERENCES log(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,                  -- person's name
    relationship    TEXT,                           -- how you know them / their role
    context         TEXT,                           -- what happened, what was discussed
    follow_up       TEXT,                           -- next action regarding this person
    UNIQUE(log_id)
);

-- ============================================================
-- IDEAS: Concepts, inspiration, half-formed notions worth
-- capturing before they vanish.
-- ============================================================
CREATE TABLE ideas (
    id              SERIAL PRIMARY KEY,
    log_id          INTEGER NOT NULL REFERENCES log(id) ON DELETE CASCADE,
    concept         TEXT NOT NULL,                  -- the core idea in one line
    details         TEXT,                           -- elaboration, reasoning, nuance
    connections     TEXT,                           -- related ideas, projects, or people
    UNIQUE(log_id)
);

-- ============================================================
-- PROJECTS: Active work. The LLM extracts the next concrete
-- action, not just a vague intention.
-- ============================================================
CREATE TABLE projects (
    id              SERIAL PRIMARY KEY,
    log_id          INTEGER NOT NULL REFERENCES log(id) ON DELETE CASCADE,
    project_name    TEXT NOT NULL,                  -- which project this relates to
    next_action     TEXT,                           -- the very next concrete step
    status          VARCHAR(20) DEFAULT 'active'
                    CHECK (status IN ('active', 'blocked', 'someday', 'done')),
    blockers        TEXT,                           -- what's in the way, if anything
    UNIQUE(log_id)
);

-- ============================================================
-- ADMIN: Tasks, logistics, errands. Things that need doing
-- but aren't project-level.
-- ============================================================
CREATE TABLE admin (
    id              SERIAL PRIMARY KEY,
    log_id          INTEGER NOT NULL REFERENCES log(id) ON DELETE CASCADE,
    task            TEXT NOT NULL,                  -- what needs to be done
    deadline        TEXT,                           -- when (free text — "by Friday", "2026-03-01", etc.)
    priority        VARCHAR(10) DEFAULT 'medium'
                    CHECK (priority IN ('high', 'medium', 'low')),
    UNIQUE(log_id)
);
```

**Key design decisions:**
- `log.seq` provides a global capture index across all buckets.
- Each bucket table has a `UNIQUE(log_id)` constraint — one bucket record per log entry.
- `ON DELETE CASCADE` means deleting a log entry cleans up the bucket record.
- When the fix button reclassifies an entry, the old bucket row is deleted and a new one is inserted (the log row's `bucket` column is updated too).
- The `log` table holds the embedding, not the bucket tables — semantic search operates on the raw thought regardless of bucket.

**Deployment:**
- Location: `kubernetes/base/apps/ai/secondbrain-db/`
- CNPG cluster: `secondbrain-16-db`, 3 replicas, `openebs-hostpath`, 5Gi
- Backup: Barman Cloud Plugin to Garage S3 (same pattern as n8n-16-db)
- ExternalSecret: Garage S3 credential pattern (`cnpg-garage-access-secondbrain`)
- Namespace: `ai`

**Files to create** (copy pattern from `kubernetes/base/apps/ai/n8n/db/`):
- `db/pg-cluster-16.yaml` — cluster definition (bookworm image, postInitSQL for schema)
- `db/objectstore-backup.yaml` — Barman backup ObjectStore
- `db/objectstore-external.yaml` — Barman external ObjectStore (for recovery)
- `db/scheduled-backup.yaml` — daily ScheduledBackup
- `db/cnpg-garage-external-secret.yaml` — Garage S3 credentials
- `db/kustomization.yaml` — bundle all db resources
- `kustomization.yaml` — top-level (includes db/)

**ArgoCD app:** `secondbrain-db-app.yaml` in `kubernetes/base/apps/ai/`

### 3. Ollama on hawk (NixOS Service)

Ollama runs on hawk (Beelink SER5 Max, AMD Ryzen 7 6800U, 24GB RAM) as a NixOS service, **not** in the K8s cluster. Testing showed qwen2.5:3b runs at ~7s/thought on hawk vs ~8min on the Orange Pi ARM nodes — a 65x speedup that makes the system practical.

The existing K8s Ollama StatefulSet on opi01-03 stays unchanged (TinyLlama for general use). The second brain uses hawk exclusively.

**New file:** `nixos/hosts/hawk/ollama.nix`

```nix
{ pkgs, ... }: {
  services.ollama = {
    enable = true;
    host = "0.0.0.0";          # Listen on all interfaces (Tailscale-accessible)
    port = 11434;
    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "5m"; # Unload models after 5 min idle
    };
  };

  # Open port for Tailscale access from K8s cluster
  networking.firewall.allowedTCPPorts = [ 11434 ];
}
```

**Modified file:** `nixos/hosts/hawk/default.nix` — add `./ollama.nix` to imports.

**Post-deploy model pull** (one-time, via SSH):
```bash
ssh hawk.internal "ollama pull qwen2.5:3b && ollama pull nomic-embed-text"
```

**Model sizes:** qwen2.5:3b ~1.9GB + nomic-embed-text ~274MB = ~2.2GB on disk. ~2.5GB RAM at inference, well within hawk's 24GB.

**Benchmarked performance** (turbo boost disabled):
- Cold start (model load + inference): ~9s
- Warm (model in memory): ~7s
- Generation speed: ~10-13 tok/s

**Endpoint from n8n:** `http://hawk.internal:11434` (via Tailscale DNS, accessible from K8s pods).

### 4. n8n Workflows (The Glue)

4 workflows. All LLM calls go to Ollama on hawk — zero external API dependencies.

**Service endpoints:**
- Ollama: `http://hawk.internal:11434`
- secondbrain-db: `secondbrain-16-db-rw.ai.svc.cluster.local:5432` (credentials from CNPG secret `secondbrain-16-db-app`)

#### Workflow 1: Capture, Embed, Classify & Extract

**ID:** `Sqk6V8PoUMyMDsQq`
**Trigger:** Schedule — every 30 seconds

**Node pipeline** (14 nodes):

1. **Schedule Trigger** (`Every 30s`) — fires every 30 seconds
2. **HTTP Request** (`Poll ntfy sb-capture`) — `GET http://ntfy.self-hosted.svc.cluster.local/sb-capture/json?poll=1&since=30s` with `fullResponse: true` (response text lands in `.data`)
3. **Code** (`Parse ntfy Messages`) — splits newline-delimited JSON, filters `event === 'message'`, extracts `{text, ntfy_id, timestamp, last_id}`. Returns `[]` if no messages (pipeline ends cleanly).
4. **HTTP Request** (`Embed (Ollama)`) — POST to `http://hawk.internal:11434/api/embeddings` with `{"model": "nomic-embed-text", "prompt": "<text>"}`
5. **PostgreSQL** (`RAG Context`) — pgvector similarity search for 5 most similar past entries. **`alwaysOutputData: true`** so the pipeline continues even when the log table is empty.
6. **Code** (`Classify & Extract`) — builds the classification prompt (including RAG context summary) and calls Ollama directly via `this.helpers.httpRequest()`. Returns `{response: "..."}` with `pairedItem: {item: 0}` for item linking.
7. **Code** (`Parse LLM Response`) — parses LLM JSON output, merges with upstream data (raw_text, ntfy_id, embedding), computes `needs_review = confidence < 0.7`
8. **PostgreSQL** (`Insert Log`) — INSERT into `log` table, RETURNING `id, seq`
9. **Switch** (`Bucket Switch`) — routes to the correct bucket INSERT based on `bucket` field
10. **PostgreSQL** (`Insert People/Ideas/Projects/Admin`) — 4 parallel nodes, one per bucket
11. **Code** (`Post Receipt to ntfy`) — posts structured JSON notification to ntfy root URL with proper `title`, `message`, `tags`, and `actions` (for low-confidence reviews)

**Key implementation details:**

- **Classify & Extract is a Code node, not HTTP Request.** Embedding RAG context JSON inside a template expression broke n8n's JSON validation. Using `this.helpers.httpRequest()` in a Code node avoids all expression/serialization issues.
- **Post Receipt is a Code node, not HTTP Request.** Same reason — building structured ntfy JSON with dynamic action buttons is cleaner in code. Posts to ntfy root URL (not `/topic`) so ntfy parses the JSON body for `title`, `message`, `tags` fields.
- **PostgreSQL queryReplacement uses single JSON parameter.** n8n's Postgres node splits `queryReplacement` values by comma, which breaks when values contain commas (raw text, embedding vectors). All INSERT nodes use `$1::jsonb` with `($1::jsonb)->>'field'` extraction to pass a single `JSON.stringify({...})` parameter. See "n8n Quirks" below.
- **RAG Context has `alwaysOutputData: true`.** Without this, an empty query result (0 items) silently terminates the pipeline.

**Classification + extraction prompt** (same as originally planned — see below for reference):

```
You are a thought classifier and extractor. Given a raw thought:
1. Classify it into exactly one bucket: people, ideas, projects, or admin.
2. Extract the structured fields for that bucket.
3. Rate your confidence from 0.0 to 1.0.

Return JSON matching ONE of these schemas depending on the bucket:
[... people/ideas/projects/admin schemas ...]

Here are similar past thoughts for context:
<RAG context JSON or "(no similar past entries)">

New thought: "<message_text>"
```

**Bouncer behavior:** `needs_review = confidence < 0.7`. Receipts go to `sb-review` (with fix action buttons) or `sb-digest` (with summary).

#### Workflow 2: Daily Morning Digest (uses Ollama)

**ID:** `0B7L5ivez9AqpeXq`
**Trigger:** Cron — every day at 7:00 AM UTC

**Node pipeline** (7 nodes):

1. **Schedule Trigger** (`Every Day 7am`) — cron `0 7 * * *`
2. **PostgreSQL** (`Query Today's Entries`) — query unfollowed-up entries from last 24h with LEFT JOINs across all bucket tables. If 0 rows returned, pipeline stops silently (correct — no digest when nothing to digest).
3. **IF** (`Has Entries?`) — guard: `$input.all().length > 0`
4. **Code** (`Prepare Entries`) — collects all query results into `JSON.stringify(entries)` and `count`
5. **Code** (`Summarize (Ollama)`) — builds the briefing prompt and calls Ollama via `this.helpers.httpRequest()`. Uses Code node (not HTTP Request) to avoid JSON interpolation issues with entries containing quotes.
6. **Code** (`Post to ntfy sb-daily`) — posts structured JSON to ntfy root URL with `topic: 'sb-daily'`, priority 3, sunrise tag
7. **PostgreSQL** (`Mark Followed Up`) — `UPDATE log SET followed_up = TRUE, follow_up_at = NOW()` for all entries in the 24h window

#### Workflow 3: Weekly Sunday Recap (uses Ollama)

**ID:** `H06P7xS44qah9Rqp`
**Trigger:** Cron — every Sunday at 10:00 AM UTC

Originally planned for Claude API, but switched to Ollama to eliminate the API key dependency. qwen2.5:3b handles the weekly recap well — tested with 6 entries producing a structured recap with themes, action items, and priorities.

**Node pipeline** (6 nodes):

1. **Schedule Trigger** (`Every Sunday 10am`) — cron `0 10 * * 0`
2. **PostgreSQL** (`Query Week's Entries`) — same LEFT JOIN query as WF2 but with `INTERVAL '7 days'` and no `followed_up` filter (includes all entries regardless of daily digest status)
3. **IF** (`Has Entries?`) — guard: `$input.all().length > 0`
4. **Code** (`Prepare Entries`) — collects all query results into `JSON.stringify(entries)` and `count`
5. **Code** (`Weekly Recap (Ollama)`) — builds the recap prompt and calls Ollama via `this.helpers.httpRequest()`. Prompt asks for themes, unresolved actions, recurring people, low-confidence flags, and next-week priorities. Returns `{recap: response.response}`.
6. **Code** (`Post to ntfy sb-weekly`) — posts structured JSON to ntfy root URL with `topic: 'sb-weekly'`, priority 4, calendar tag

#### Workflow 4: Fix Handler

**ID:** `vs8PxIKu6zoF7Gwj`
**Trigger:** n8n Webhook node — receives HTTP requests from ntfy action buttons.

When a user taps a bucket button on a low-confidence receipt notification, ntfy sends an HTTP request to the n8n webhook with the log entry ID and the correct bucket as query parameters.

**Webhook URL:** `https://n8n.internal/webhook/sb-fix?id=<log_id>&bucket=<new_bucket>`

**Node pipeline** (12 nodes):

1. **Webhook** (`Fix Webhook`) — GET `/sb-fix`, reads `id` and `bucket` from query params. Uses `responseMode: responseNode` so the response is sent by the Respond OK node at the end.
2. **PostgreSQL** (`Get Log Entry`) — `SELECT id, raw_text, bucket AS old_bucket FROM log WHERE id = $1`
3. **Code** (`Re-Extract (Ollama)`) — builds a forced-bucket extraction prompt and calls Ollama via `this.helpers.httpRequest()`. Uses Code node (not HTTP Request) to safely embed raw_text in the prompt. Returns `{response: "..."}` with `pairedItem`.
4. **Code** (`Parse Fix Response`) — parses LLM JSON, merges `log_id`, `new_bucket`, `old_bucket`
5. **PostgreSQL** (`Update Log & Clear Old Bucket`) — CTE that DELETEs from all 4 bucket tables and UPDATEs `log.bucket` + `needs_review = false`. Uses `$1::jsonb` pattern.
6. **Switch** (`New Bucket Switch`) — routes to the correct bucket INSERT
7. **PostgreSQL** (`Insert People/Ideas/Projects/Admin (Fix)`) — 4 parallel nodes, one per bucket. All use `$1::jsonb` pattern.
8. **Code** (`Notify Fix to ntfy`) — posts confirmation to ntfy root URL with `topic: 'sb-digest'`, title like `Fixed #6 -> [projects] (was: ideas)`, hammer_and_wrench tag
9. **Respond to Webhook** (`Respond OK`) — returns `Fixed #<id> -> [<bucket>]` as plain text

**Advantage over v2:** Instant — no 60s polling delay. The fix happens the moment the user taps the button.

## Deployment Order

1. **ntfy** — simplest, no dependencies. Test push notifications to phone. **DONE**
   - Created: `kubernetes/base/apps/self-hosted/ntfy/` (deployment, service, ingress, kustomization)
   - Created: `kubernetes/base/apps/self-hosted/ntfy-app.yaml`
   - Added to: `kubernetes/base/apps/self-hosted/kustomization.yaml`

2. **Ollama on hawk** — deploy NixOS service, pull models. **DONE**
   - Created: `nixos/hosts/hawk/ollama.nix`
   - Modified: `nixos/hosts/hawk/default.nix` (add import)
   - Deployed: `just nix deploy hawk`
   - Models pulled: qwen2.5:3b, nomic-embed-text

3. **secondbrain-db** — CNPG cluster with pgvector + full schema. **DONE**
   - Created: `kubernetes/base/apps/ai/secondbrain-db/` (full db/ subdirectory)
   - Created: `kubernetes/base/apps/ai/secondbrain-db-app.yaml`
   - Added to: `kubernetes/base/apps/ai/kustomization.yaml`

4. **n8n workflows** — build the 4 workflows via n8n API. **DONE**
   - Created PostgreSQL credential `SecondBrain PostgreSQL` for `secondbrain-16-db-rw.ai.svc.cluster.local`
   - Built Workflow 1: `Sqk6V8PoUMyMDsQq` — Capture, Embed, Classify & Extract
   - Built Workflow 4: `vs8PxIKu6zoF7Gwj` — Fix Handler (webhook)
   - Built Workflow 2: `0B7L5ivez9AqpeXq` — Daily Morning Digest
   - Built Workflow 3: `H06P7xS44qah9Rqp` — Weekly Sunday Recap
   - All 4 workflows verified end-to-end

## Files Created/Modified

All infrastructure is deployed. n8n workflows are stored in n8n's database (not in git).

### Created:
```
nixos/hosts/hawk/ollama.nix                              — Ollama NixOS service config

kubernetes/base/apps/self-hosted/ntfy/
  deployment.yaml
  service.yaml
  ingress.yaml
  kustomization.yaml
kubernetes/base/apps/self-hosted/ntfy-app.yaml

kubernetes/base/apps/ai/secondbrain-db/
  db/pg-cluster-16.yaml
  db/objectstore-backup.yaml
  db/objectstore-external.yaml
  db/scheduled-backup.yaml
  db/cnpg-garage-external-secret.yaml
  db/kustomization.yaml
  kustomization.yaml
kubernetes/base/apps/ai/secondbrain-db-app.yaml
```

### Modified:
```
nixos/hosts/hawk/default.nix                             — add ./ollama.nix import
kubernetes/base/apps/ai/kustomization.yaml               — add secondbrain-db-app.yaml
kubernetes/base/apps/self-hosted/kustomization.yaml       — add ntfy-app.yaml
```

## Verification

### After each deployment step:

1. **ntfy**: `curl -d "test" https://ntfy.internal/test` -> phone receives push notification **DONE**
2. **Ollama on hawk**: `ssh hawk.internal "ollama list"` shows qwen2.5:3b and nomic-embed-text; `curl http://hawk.internal:11434/api/tags` responds from K8s pod network **DONE**
3. **secondbrain-db**: `kubectl get cluster -n ai secondbrain-16-db` shows 3/3 ready; pgvector extension and all 5 tables present **DONE**
4. **n8n workflows**: **DONE** (all 4 workflows verified end-to-end)
   - Sent "Need to renew my driver's license before March 15th" -> `#1 [admin] (100%)` with task/deadline/priority extracted
   - Sent "Had coffee with Jake yesterday, he mentioned wanting to collaborate..." (comma in text) -> `#2 [people] (100%)` with name/context/follow_up extracted
   - Sent "I should look into building a mesh network for the backyard sensors, maybe using LoRa" -> `#3 [ideas] (100%)` with concept/details extracted
   - Sent "The k3s cluster needs a RAM upgrade on raccoon02, it keeps OOMing" -> `#4 [admin] (100%)` with task/priority=high
   - Sent "Talked to Maria about the garden redesign, she suggested using native plants" -> `#5 [people] (100%)`
   - Sent "I want to try making sourdough bread this weekend" -> `#6 [ideas] (100%)`
   - Receipts arrive on `sb-digest` with structured title/message/tags
   - **Workflow 2 (Daily Digest)**: Triggered manually -> queried 6 entries -> Ollama generated a structured morning briefing -> posted to `sb-daily` -> marked all 6 entries `followed_up = TRUE`
   - **Workflow 3 (Weekly Recap)**: Triggered manually -> queried 6 entries -> Ollama generated a detailed weekly recap with themes, action items, and priorities -> posted to `sb-weekly`
   - **Workflow 4 (Fix Handler)**: `curl 'https://n8n.internal/webhook/sb-fix?id=6&bucket=projects'` -> reclassified entry #6 from `ideas` to `projects` -> old ideas row deleted, new projects row created (`Make Sourdough Bread`, `next_action: Purchase ingredients...`) -> ntfy confirmation `Fixed #6 -> [projects] (was: ideas)`
   - **Still to test**: low-confidence bouncer (needs_review flow via real low-confidence classification)

### End-to-end smoke test:

1. Publish 5 thoughts to `sb-capture` covering all 4 buckets
2. Verify `sb-digest` receipts show correct extracted fields per bucket
3. Publish 1 ambiguous thought -> lands on `sb-review` -> fix it with action button
4. Verify DB: each bucket table has the correct rows with extracted fields
5. Query pgvector similarity:
   ```sql
   SELECT l.seq, l.bucket, l.raw_text
   FROM log l
   ORDER BY l.embedding <=> (SELECT embedding FROM log WHERE seq = 1)
   LIMIT 3;
   ```

## n8n Quirks (Lessons Learned)

These are bugs and workarounds discovered during Workflow 1 implementation. Document them here so future workflow edits don't reintroduce them.

1. **`queryReplacement` splits by ALL commas.** n8n's Postgres node evaluates the `queryReplacement` expression as one string, then splits it by commas to produce positional parameters (`$1`, `$2`, ...). If any value contains a comma (raw text like "Had coffee with Jake**,** he mentioned..." or embedding vectors like `[0.02, 1.53, ...]`), the split misaligns all parameters. **Workaround:** Pass a single `JSON.stringify({...})` as `$1`, then extract fields in SQL with `($1::jsonb)->>'field_name'`. This avoids the comma problem entirely.

2. **`alwaysOutputData` is required on Postgres nodes that may return 0 rows.** When a Postgres query returns no results, n8n produces 0 output items, which silently terminates the pipeline (downstream nodes never execute). Set `alwaysOutputData: true` on any Postgres node whose output feeds the main pipeline. The RAG Context node hit this when the log table was empty.

3. **Code nodes must set `pairedItem` for downstream `$('NodeName').item` references.** When a Code node produces output items, n8n needs item-linking metadata to resolve expressions like `$('Parse ntfy Messages').item.json.text` in downstream nodes. Without `pairedItem: {item: 0}`, you get `ExpressionError: Paired item data for item from node ... is unavailable`.

4. **HTTP Request `jsonBody` expressions can't embed JSON strings.** If a `jsonBody` expression includes `JSON.stringify(someObject)` inside a template string (e.g., for an LLM prompt), the resulting JSON may have unescaped quotes that fail validation with `JSON parameter needs to be valid JSON`. **Workaround:** Use a Code node with `this.helpers.httpRequest()` instead. This lets you build the request body in JavaScript where escaping is handled naturally.

5. **ntfy structured JSON requires POST to root URL.** When POSTing to `ntfy.internal/topic-name`, ntfy treats the entire body as the message text. To use structured JSON fields (`title`, `message`, `tags`, `actions`), POST to the root URL `ntfy.internal/` with `topic` in the JSON body and `Content-Type: application/json`.

6. **n8n API `active` is read-only on PUT.** To activate/deactivate workflows via API, use the dedicated `POST /workflows/{id}/activate` and `POST /workflows/{id}/deactivate` endpoints. The `active` field is silently ignored on PUT.

7. **HTTP Request `fullResponse: true` puts data in `.data`, not `.body`.** When `fullResponse` is enabled, the response text is in `$json.data`, not `$json.body`. The statusCode and headers are at the top level.

8. **Cron schedule changes require deactivate/activate cycle.** After updating a workflow's cron expression via API PUT, the internal scheduler doesn't pick up the change. You must `POST /workflows/{id}/deactivate` then `POST /workflows/{id}/activate` for the new cron to take effect.

## Known Limitations

- **Fix button re-extracts**: Reclassifying deletes the old bucket row and re-runs extraction. If the model extracts poorly, manual SQL is needed.
- **IVFFlat index accuracy**: With few entries (<100), results may be imprecise. Skip the index until ~500 entries, or use exact search (remove the index, `<=>` still works).
- **nomic-embed-text is English-focused**: Multilingual thoughts may embed poorly.
- **Ollama cold start**: First inference after model unload takes ~9s on hawk. The 5m keep-alive mitigates this for burst captures.
- **hawk dependency**: If hawk is down, all LLM features stop (classification, daily digest, weekly recap). hawk is always-on with auto-upgrade, so this is low risk.
- **3B model extraction quality**: qwen2.5:3b may occasionally miss fields or hallucinate values. The bouncer catches low-confidence cases, but some extracted fields (e.g., `relationship`, `deadline`) may need manual correction. Tested: classification accuracy is good but bucket choice can be ambiguous (e.g., "ping Sarah" classified as admin vs people — the fix button handles this).
- **ntfy message length**: ntfy notifications are limited to ~4096 bytes. Daily/weekly digests that exceed this will need truncation or a link to a full version.

## Future Enhancements (Out of Scope)

- Kanboard integration (auto-create cards for `projects` bucket items)
- Wiki.js integration (auto-create pages for `ideas` bucket)
- Semantic search UI (web page to query "thoughts like X")
- Multi-model routing (use NPU TFLite for embedding instead of Ollama)
- Spaced repetition (resurface old ideas on a schedule)
- Chat-based capture UI (if a proper arm64-compatible chat platform emerges)
