# Second Brain System Plan (v3)

## Context

Revision of the second brain plan (Forgejo issue #100), incorporating:

1. **Energy-efficient local AI**: Replace most Claude API calls with local Ollama inference (qwen2.5:3b on hawk). Add pgvector for semantic search (RAG). Keep Claude API only for the weekly recap.
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
                                              │  ┌─────────────┐                          │
                                              │  │ Claude API  │  (weekly recap only)     │
                                              │  └─────────────┘                          │
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
| Weekly recap | Claude API | Claude API | Claude API |
| Embeddings | Not planned | nomic-embed-text | nomic-embed-text |
| Vector search | "Future enhancement" | pgvector | pgvector |
| Confidence scoring | Not planned | Core | Core |
| Quality gate | Not planned | Core | Core |
| Fix button | "Future enhancement" | Emoji reactions | **ntfy action buttons** |
| DB schema | 1 flat table | 5 tables | 5 tables |
| Monthly API cost | ~$0.60 | ~$0.02 | ~$0.02 |
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

4 workflows. LLM calls go to Ollama (local) except the weekly recap.

**Service endpoints:**
- Ollama: `http://hawk.internal:11434`
- secondbrain-db: `secondbrain-16-db-rw.ai.svc.cluster.local:5432` (credentials from CNPG secret `secondbrain-16-db-app`)

#### Workflow 1: Capture, Embed, Classify & Extract

**Trigger:** n8n polls ntfy subscription endpoint (`GET ntfy.internal/sb-capture/json?poll=1&since=<last_id>`) on a schedule (every 30s), or uses Server-Sent Events for real-time.

Steps:

1. **HTTP Request node** — poll ntfy for new messages on `sb-capture` topic. Each message contains the raw thought text and an `id` field.

2. **HTTP Request node** (embed) — POST to Ollama `/api/embeddings`:
   ```json
   {"model": "nomic-embed-text", "prompt": "<message_text>"}
   ```

3. **PostgreSQL node** (RAG context) — find 5 most similar past thoughts:
   ```sql
   SELECT l.bucket, l.confidence,
          p.name, p.context,
          i.concept,
          pr.project_name, pr.next_action,
          a.task
   FROM log l
   LEFT JOIN people p ON p.log_id = l.id
   LEFT JOIN ideas i ON i.log_id = l.id
   LEFT JOIN projects pr ON pr.log_id = l.id
   LEFT JOIN admin a ON a.log_id = l.id
   WHERE l.embedding IS NOT NULL
   ORDER BY l.embedding <=> $1::vector
   LIMIT 5;
   ```

4. **HTTP Request node** (classify + extract) — POST to Ollama `/api/generate`:
   ```json
   {
     "model": "qwen2.5:3b",
     "stream": false,
     "format": "json",
     "prompt": "..."
   }
   ```

   **Classification + extraction prompt:**
   ```
   You are a thought classifier and extractor. Given a raw thought:
   1. Classify it into exactly one bucket: people, ideas, projects, or admin.
   2. Extract the structured fields for that bucket.
   3. Rate your confidence from 0.0 to 1.0.

   Return JSON matching ONE of these schemas depending on the bucket:

   If "people":
   {"bucket": "people", "confidence": 0.0-1.0,
    "name": "person's name",
    "relationship": "how you know them (nullable)",
    "context": "what happened or was discussed",
    "follow_up": "next action regarding this person (nullable)"}

   If "ideas":
   {"bucket": "ideas", "confidence": 0.0-1.0,
    "concept": "the core idea in one line",
    "details": "elaboration or reasoning (nullable)",
    "connections": "related ideas, projects, or people (nullable)"}

   If "projects":
   {"bucket": "projects", "confidence": 0.0-1.0,
    "project_name": "which project",
    "next_action": "the very next concrete step (nullable)",
    "status": "active|blocked|someday",
    "blockers": "what's in the way (nullable)"}

   If "admin":
   {"bucket": "admin", "confidence": 0.0-1.0,
    "task": "what needs to be done",
    "deadline": "when, if mentioned (nullable)",
    "priority": "high|medium|low"}

   Here are similar past thoughts for context:
   <similar_entries_json>

   New thought: "<message_text>"
   ```

5. **IF node** (bouncer) — check `confidence`:
   - **>= 0.7**: auto-file (happy path)
   - **< 0.7**: set `needs_review = TRUE`, publish to `sb-review` instead of `sb-digest`

6. **PostgreSQL node** — INSERT into `log` table (raw_text, bucket, confidence, needs_review, embedding, source_post_id). Get the `log.id` back.

7. **Switch node** — based on `bucket`, INSERT into the correct bucket table:
   - `people` → INSERT INTO people (log_id, name, relationship, context, follow_up)
   - `ideas` → INSERT INTO ideas (log_id, concept, details, connections)
   - `projects` → INSERT INTO projects (log_id, project_name, next_action, status, blockers)
   - `admin` → INSERT INTO admin (log_id, task, deadline, priority)

8. **HTTP Request node** — publish receipt to ntfy:
   - **High confidence** → POST to `ntfy.internal/sb-digest`:
     ```
     Title: #42 [projects] (94%)
     Body: "Build second brain" — next: write deployment manifests
     Tags: white_check_mark
     ```
   - **Low confidence** → POST to `ntfy.internal/sb-review` with action buttons:
     ```
     Title: #42 Needs review (42%)
     Body: "Talk to Sam about the thing"
     Tags: warning
     Actions: http, People, <n8n-webhook>/sb-fix?id=42&bucket=people;
              http, Ideas, <n8n-webhook>/sb-fix?id=42&bucket=ideas;
              http, Projects, <n8n-webhook>/sb-fix?id=42&bucket=projects;
              http, Admin, <n8n-webhook>/sb-fix?id=42&bucket=admin
     ```

   The receipt includes the log `seq` number and a human-readable summary of the extracted fields.

#### Workflow 2: Daily Morning Digest (uses Ollama)

**Trigger:** Cron — every day at 7:00 AM

Steps:

1. **Schedule Trigger node**
2. **PostgreSQL node** — query unfollowed-up entries from last 24h with extracted fields:
   ```sql
   SELECT l.id, l.seq, l.bucket, l.confidence, l.needs_review, l.created_at,
          p.name, p.context, p.follow_up,
          i.concept, i.details,
          pr.project_name, pr.next_action, pr.status, pr.blockers,
          a.task, a.deadline, a.priority
   FROM log l
   LEFT JOIN people p ON p.log_id = l.id
   LEFT JOIN ideas i ON i.log_id = l.id
   LEFT JOIN projects pr ON pr.log_id = l.id
   LEFT JOIN admin a ON a.log_id = l.id
   WHERE l.followed_up = FALSE
     AND l.created_at >= NOW() - INTERVAL '24 hours'
   ORDER BY l.bucket, l.created_at;
   ```
3. **IF node** — skip if no entries
4. **HTTP Request node** — POST to Ollama `/api/generate` (qwen2.5:3b):
   ```
   Here are yesterday's captured thoughts, organized by bucket with extracted details.
   Write a brief morning briefing (5-10 lines) highlighting:
   - Action items from 'projects' (include next actions) and 'admin' (include deadlines)
   - Notable people to follow up with (include the follow-up action)
   - Interesting ideas worth revisiting
   - Items needing review (low confidence, marked with *)

   <entries JSON>
   ```
5. **HTTP Request node** — POST to `ntfy.internal/sb-daily` (priority: 3, title: "Morning Briefing")
6. **PostgreSQL node** — UPDATE log SET `followed_up = TRUE, follow_up_at = NOW()`

#### Workflow 3: Weekly Sunday Recap (Claude API)

**Trigger:** Cron — every Sunday at 10:00 AM

This stays on Claude API — synthesizing weekly patterns requires more reasoning than a 3B model handles well.

Steps:

1. **Schedule Trigger node**
2. **PostgreSQL node** — query all entries from past 7 days (same JOIN query as daily, but `INTERVAL '7 days'`)
3. **IF node** — skip if no entries
4. **Anthropic node** (Claude Haiku or Sonnet):
   ```
   Here are all captured thoughts from this week, organized by bucket with
   their extracted details.

   Write a weekly recap (15-20 lines) that:
   - Summarizes themes and patterns across the week
   - Lists unresolved project next-actions and admin tasks with deadlines
   - Notes recurring people and suggests follow-ups
   - Flags any items that were low-confidence and may need attention
   - Suggests 2-3 priorities for next week

   <entries JSON>
   ```
5. **HTTP Request node** — POST to `ntfy.internal/sb-weekly` (priority: 4, title: "Weekly Recap")

#### Workflow 4: Fix Handler

**Trigger:** n8n Webhook node — receives HTTP requests from ntfy action buttons.

When a user taps a bucket button on a low-confidence receipt notification, ntfy sends an HTTP request to the n8n webhook with the log entry ID and the correct bucket as query parameters.

**Webhook URL:** `https://n8n.internal/webhook/sb-fix?id=<log_id>&bucket=<new_bucket>`

Steps:

1. **Webhook node** — receives `id` and `bucket` from ntfy action button click
2. **PostgreSQL node** — get the log entry + raw_text by id
3. **HTTP Request node** — POST to Ollama `/api/generate` with the raw_text and the **forced bucket**:
   ```
   Extract structured fields for the "<new_bucket>" bucket from this thought.
   The bucket has already been decided — do not reclassify.

   Return JSON matching the schema for <new_bucket>:
   (... schema for that bucket only ...)

   Thought: "<raw_text>"
   ```
4. **PostgreSQL node** — in a transaction:
   - DELETE from old bucket table WHERE log_id = $1
   - UPDATE log SET bucket = $2, needs_review = FALSE WHERE id = $1
   - INSERT into new bucket table with extracted fields
5. **HTTP Request node** — publish confirmation to `ntfy.internal/sb-digest`:
   ```
   Title: Fixed #42 -> [people] (was: ideas)
   Tags: hammer_and_wrench
   ```

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

4. **n8n workflows** — build the 4 workflows in n8n UI.
   - Subscribe ntfy phone app to `sb-capture`, `sb-digest`, `sb-review`, `sb-daily`, `sb-weekly` topics
   - Create PostgreSQL credential for secondbrain-16-db
   - Build Workflow 1 (capture + embed + classify + extract + bouncer)
   - Build Workflow 4 (fix handler webhook) — test with Workflow 1
   - Build Workflow 2 (daily digest)
   - Build Workflow 3 (weekly recap)

## Files Created/Modified

All infrastructure files are deployed. Only n8n workflows (built in the UI) remain.

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
4. **n8n workflows**:
   - Publish "Had lunch with Sarah from the ML team, should follow up about the NPU project" to `sb-capture`
     -> receipt on `sb-digest`: `#1 [people] (87%) Sarah — ML team, follow up re: NPU project`
   - Publish "hmm maybe something about containers" to `sb-capture`
     -> receipt on `sb-review` (low confidence) with 4 bucket action buttons
   - Tap "Ideas" button on the review notification -> fix handler fires -> `Fixed #2 -> [ideas] (was: projects)`
   - Trigger daily digest manually -> `sb-daily` notification with both entries
   - Run weekly recap manually -> `sb-weekly` notification with Claude API recap

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

## Known Limitations

- **Fix button re-extracts**: Reclassifying deletes the old bucket row and re-runs extraction. If the model extracts poorly, manual SQL is needed.
- **IVFFlat index accuracy**: With few entries (<100), results may be imprecise. Skip the index until ~500 entries, or use exact search (remove the index, `<=>` still works).
- **nomic-embed-text is English-focused**: Multilingual thoughts may embed poorly.
- **Ollama cold start**: First inference after model unload takes ~9s on hawk. The 5m keep-alive mitigates this for burst captures.
- **hawk dependency**: If hawk is down, classification and daily digests stop (weekly recap still works via Claude API). hawk is always-on with auto-upgrade, so this is low risk.
- **3B model extraction quality**: qwen2.5:3b may occasionally miss fields or hallucinate values. The bouncer catches low-confidence cases, but some extracted fields (e.g., `relationship`, `deadline`) may need manual correction. Tested: classification accuracy is good but bucket choice can be ambiguous (e.g., "ping Sarah" classified as admin vs people — the fix button handles this).
- **ntfy message length**: ntfy notifications are limited to ~4096 bytes. Daily/weekly digests that exceed this will need truncation or a link to a full version.

## Future Enhancements (Out of Scope)

- Kanboard integration (auto-create cards for `projects` bucket items)
- Wiki.js integration (auto-create pages for `ideas` bucket)
- Semantic search UI (web page to query "thoughts like X")
- Multi-model routing (use NPU TFLite for embedding instead of Ollama)
- Spaced repetition (resurface old ideas on a schedule)
- Chat-based capture UI (if a proper arm64-compatible chat platform emerges)
