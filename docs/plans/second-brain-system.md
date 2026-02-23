# Second Brain System Plan (v2)

## Context

Revision of the original second brain plan (Forgejo issue #100), incorporating:

1. **Energy-efficient local AI**: Replace most Claude API calls with local Ollama inference (qwen2.5:3b on hawk). Add pgvector for semantic search (RAG). Keep Claude API only for the weekly recap.
2. **GRAB system resilience patterns** ([Nate Jones](https://natesnewsletter.substack.com/p/grab-the-system-that-closes-open)): Confidence scoring (receipt), quality gate (bouncer), and fix button — the trust-building feedback loop that prevents second brain systems from dying.
3. **Per-bucket structured extraction**: Each bucket has its own schema. The LLM doesn't just classify — it extracts the pertinent fields for that bucket type. A `log` table keeps the full raw record with capture time and sequence.

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
│ Phone/Desktop│────▶│ Mattermost       │────▶│ n8n (4 workflows)                         │
│ (capture)    │     │ #capture channel │     │          │                                │
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
                     ┌────────────────┐   ┌─────────────────┐   ┌───────────────┐
                     │ PostgreSQL     │   │ Mattermost      │   │ ntfy          │
                     │ + pgvector     │   │ #digest channel  │   │ (push notify) │
                     │                │   │ #review channel  │   │ daily/weekly  │
                     │ log (master)   │   │ (receipts, fix)  │   └───────────────┘
                     │ people         │   └─────────────────┘
                     │ ideas          │
                     │ projects       │
                     │ admin          │
                     └────────────────┘
```

## What Changes vs Original Plan

| Area | Original | Revised |
|---|---|---|
| Classification | Claude API | Ollama qwen2.5:3b (on hawk) |
| Daily digest | Claude API | Ollama qwen2.5:3b (on hawk) |
| Weekly recap | Claude API | Claude API (kept) |
| Embeddings | Not planned | nomic-embed-text via Ollama |
| Vector search | "Future enhancement" | Core — pgvector in secondbrain-db |
| Context retrieval | Not planned | RAG — retrieve similar thoughts before classify |
| Confidence scoring | Not planned | Core — JSON output includes confidence 0.0-1.0 |
| Quality gate | Not planned | Core — low-confidence entries flagged for review |
| Fix button | "Future enhancement" | Core — emoji reactions trigger reclassification |
| DB schema | 1 flat table | 5 tables: log + 4 per-bucket with extracted fields |
| Monthly API cost | ~$0.60 | ~$0.02 (weekly recap only) |
| Workflows | 3 | 4 (added fix handler) |

## Components

### 1. Mattermost (Capture Conduit)

Self-hosted team chat for capture and bot interaction.

- Location: `kubernetes/base/apps/self-hosted/mattermost/`
- Helm chart: `mattermost/mattermost-team-edition`
- Database: CNPG `mattermost-16-db` (3 replicas, opi5+ affinity)
- Storage: Longhorn PVC (VolSync backup)
- Ingress: `mattermost.internal`
- Namespace: `self-hosted`
- Resources: ~512MB-1GB RAM, 200m-500m CPU

**Post-deploy setup:**
- Create bot account `secondbrain-bot`
- Create team + channels: `#capture`, `#digest`, `#review`
- Outgoing webhook on `#capture` -> n8n
- Custom emoji for buckets: `:people:`, `:ideas:`, `:projects:`, `:admin:` (for fix button)

### 2. ntfy (Push Notifications)

Self-hosted push notification server.

- Location: `kubernetes/base/apps/self-hosted/ntfy/`
- Image: `binwiederhier/ntfy`
- Resources: ~64MB RAM, 50m CPU
- Storage: 1Gi PVC (Longhorn, VolSync backup)
- Ingress: `ntfy.internal`
- Namespace: `self-hosted`
- Topics: `secondbrain-daily`, `secondbrain-weekly`

### 3. Second-Brain Database (CNPG PostgreSQL + pgvector)

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
    source_post_id  VARCHAR(100),                  -- Mattermost post ID (for fix button)
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

### 4. Ollama on hawk (NixOS Service)

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

### 5. n8n Workflows (The Glue)

4 workflows. LLM calls go to Ollama (local) except the weekly recap.

**Service endpoints:**
- Ollama: `http://hawk.internal:11434`
- secondbrain-db: `secondbrain-16-db-rw.ai.svc.cluster.local:5432` (credentials from CNPG secret `secondbrain-16-db-app`)

#### Workflow 1: Capture, Embed, Classify & Extract

**Trigger:** Mattermost outgoing webhook (message in `#capture`)

Steps:

1. **Webhook node** — receives Mattermost payload (text, post_id, timestamp)

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
   - **< 0.7**: set `needs_review = TRUE`, post to `#review` instead of `#digest`

6. **PostgreSQL node** — INSERT into `log` table (raw_text, bucket, confidence, needs_review, embedding, source_post_id). Get the `log.id` back.

7. **Switch node** — based on `bucket`, INSERT into the correct bucket table:
   - `people` → INSERT INTO people (log_id, name, relationship, context, follow_up)
   - `ideas` → INSERT INTO ideas (log_id, concept, details, connections)
   - `projects` → INSERT INTO projects (log_id, project_name, next_action, status, blockers)
   - `admin` → INSERT INTO admin (log_id, task, deadline, priority)

8. **Mattermost node** — post receipt to `#digest` or `#review`:
   - High confidence: `#42 [projects] (94%) "Build second brain" — next: write deployment manifests`
   - Low confidence: `#42 Needs review (42%) "Talk to Sam about the thing" — :people: :ideas: :projects: :admin:`

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
5. **HTTP Request node** — POST to `ntfy.internal/secondbrain-daily` (priority: 3)
6. **Mattermost node** — post full digest to `#digest`
7. **PostgreSQL node** — UPDATE log SET `followed_up = TRUE, follow_up_at = NOW()`

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
5. **HTTP Request node** — POST to `ntfy.internal/secondbrain-weekly` (priority: 4)
6. **Mattermost node** — post full recap to `#digest`

#### Workflow 4: Fix Handler

**Trigger:** Cron — every 60 seconds (polls Mattermost API for new emoji reactions)

Mattermost outgoing webhooks don't fire on emoji reactions. This workflow polls for bucket emoji reactions on receipt messages.

Steps:

1. **Schedule Trigger node** — every 60s
2. **HTTP Request node** — GET recent posts with reactions from `#review` and `#digest` via Mattermost API
3. **IF node** — filter for bucket emoji reactions (`:people:`, `:ideas:`, `:projects:`, `:admin:`)
4. **Code node** — extract log `seq` from the post text, map emoji to new bucket name
5. **PostgreSQL node** — get the log entry + raw_text by seq number
6. **HTTP Request node** — POST to Ollama `/api/generate` with the raw_text and the **forced bucket**:
   ```
   Extract structured fields for the "<new_bucket>" bucket from this thought.
   The bucket has already been decided — do not reclassify.

   Return JSON matching the schema for <new_bucket>:
   (... schema for that bucket only ...)

   Thought: "<raw_text>"
   ```
7. **PostgreSQL node** — in a transaction:
   - DELETE from old bucket table WHERE log_id = $1
   - UPDATE log SET bucket = $2, needs_review = FALSE WHERE id = $1
   - INSERT into new bucket table with extracted fields
8. **Mattermost node** — reply in thread: `Fixed #42 -> [people] (was: ideas)`

**Note:** Polling every 60s is simple and reliable. A future improvement could use Mattermost's WebSocket API for instant reactions.

## Deployment Order

1. **ntfy** — simplest, no dependencies. Test push notifications to phone.
   - Create: `kubernetes/base/apps/self-hosted/ntfy/` (deployment, service, ingress, kustomization)
   - Create: `kubernetes/base/apps/self-hosted/ntfy-app.yaml`
   - Add to: `kubernetes/base/apps/self-hosted/kustomization.yaml`

2. **Ollama on hawk** — deploy NixOS service, pull models.
   - Create: `nixos/hosts/hawk/ollama.nix`
   - Modify: `nixos/hosts/hawk/default.nix` (add import)
   - Deploy: `just nix deploy hawk`
   - Pull models: `ssh hawk.internal "ollama pull qwen2.5:3b && ollama pull nomic-embed-text"`

3. **secondbrain-db** — CNPG cluster with pgvector + full schema.
   - Create: `kubernetes/base/apps/ai/secondbrain-db/` (full db/ subdirectory)
   - Create: `kubernetes/base/apps/ai/secondbrain-db-app.yaml`
   - Add to: `kubernetes/base/apps/ai/kustomization.yaml`
   - Create Bitwarden items for Garage S3 access (or reuse existing key)

4. **Mattermost** — deploy, create bot, channels, webhooks, custom emoji.
   - Create: `kubernetes/base/apps/self-hosted/mattermost/` (helm values, db, ingress)
   - Create: `kubernetes/base/apps/self-hosted/mattermost-app.yaml`
   - Add to: `kubernetes/base/apps/self-hosted/kustomization.yaml`
   - Manual post-deploy: bot account, channels, webhooks, emoji

5. **n8n workflows** — build the 4 workflows in n8n UI.
   - Create PostgreSQL credential for secondbrain-16-db
   - Build Workflow 1 (capture + embed + classify + extract + bouncer)
   - Build Workflow 4 (fix handler) — test with Workflow 1
   - Build Workflow 2 (daily digest)
   - Build Workflow 3 (weekly recap)

## Files to Create/Modify

### New files:
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

kubernetes/base/apps/self-hosted/mattermost/
  (helm values, db cluster, ingress — TBD during implementation)
kubernetes/base/apps/self-hosted/mattermost-app.yaml
```

### Modified files:
```
nixos/hosts/hawk/default.nix                             — add ./ollama.nix import
kubernetes/base/apps/ai/kustomization.yaml               — add secondbrain-db-app.yaml
kubernetes/base/apps/self-hosted/kustomization.yaml       — add ntfy-app.yaml, mattermost-app.yaml
```

### Key pattern files to copy from:
```
nixos/personalities/development/ai.nix                   — Ollama NixOS service pattern (calypso/CUDA)
kubernetes/base/apps/ai/n8n/db/                          — CNPG cluster + Barman backup pattern
kubernetes/base/apps/ai/n8n-app.yaml                     — multi-source ArgoCD app with VolSync
kubernetes/base/apps/self-hosted/kanboard/kustomization.yaml — simple VolSync app pattern
kubernetes/base/apps/self-hosted/homebox/                 — simple deployment pattern
```

## Verification

### After each deployment step:

1. **ntfy**: `curl -d "test" https://ntfy.internal/test` -> phone receives push notification
2. **Ollama on hawk**: `ssh hawk.internal "ollama list"` shows qwen2.5:3b and nomic-embed-text; `curl http://hawk.internal:11434/api/tags` responds from K8s pod network
3. **secondbrain-db**:
   - `kubectl get cluster -n ai secondbrain-16-db` shows 3/3 ready
   - Connect and verify: `SELECT extname FROM pg_extension WHERE extname = 'vector'` returns a row
   - Verify all 5 tables exist: `\dt` shows log, people, ideas, projects, admin
4. **Mattermost**: browse to `mattermost.internal`, verify #capture, #digest, #review channels
5. **n8n workflows**:
   - Post "Had lunch with Sarah from the ML team, should follow up about the NPU project" in #capture
     -> receipt in #digest: `#1 [people] (87%) Sarah — ML team, follow up re: NPU project`
   - Post "hmm maybe something about containers" in #capture
     -> receipt in #review (low confidence): `#2 Needs review (38%) — :people: :ideas: :projects: :admin:`
   - React with `:ideas:` on the review post -> fix handler fires -> `Fixed #2 -> [ideas] (was: projects)`
   - Trigger daily digest manually -> includes both entries with extracted details
   - Run weekly recap manually -> Claude API produces structured recap

### End-to-end smoke test:

1. Post 5 thoughts covering all 4 buckets
2. Verify receipts show correct extracted fields per bucket
3. Post 1 ambiguous thought -> lands in #review -> fix it with emoji
4. Verify DB: each bucket table has the correct rows with extracted fields
5. Query pgvector similarity:
   ```sql
   SELECT l.seq, l.bucket, l.raw_text
   FROM log l
   ORDER BY l.embedding <=> (SELECT embedding FROM log WHERE seq = 1)
   LIMIT 3;
   ```

## Known Limitations

- **Mattermost reaction polling**: 60s delay between emoji reaction and fix. Could improve with WebSocket listener later.
- **Fix button re-extracts**: Reclassifying deletes the old bucket row and re-runs extraction. If the model extracts poorly, manual SQL is needed.
- **IVFFlat index accuracy**: With few entries (<100), results may be imprecise. Skip the index until ~500 entries, or use exact search (remove the index, `<=>` still works).
- **nomic-embed-text is English-focused**: Multilingual thoughts may embed poorly.
- **Ollama cold start**: First inference after model unload takes ~9s on hawk. The 5m keep-alive mitigates this for burst captures.
- **hawk dependency**: If hawk is down, classification and daily digests stop (weekly recap still works via Claude API). hawk is always-on with auto-upgrade, so this is low risk.
- **3B model extraction quality**: qwen2.5:3b may occasionally miss fields or hallucinate values. The bouncer catches low-confidence cases, but some extracted fields (e.g., `relationship`, `deadline`) may need manual correction. Tested: classification accuracy is good but bucket choice can be ambiguous (e.g., "ping Sarah" classified as admin vs people — the fix button handles this).

## Future Enhancements (Out of Scope)

- Kanboard integration (auto-create cards for `projects` bucket items)
- Wiki.js integration (auto-create pages for `ideas` bucket)
- Mattermost WebSocket listener for instant fix reactions
- Semantic search UI (web page to query "thoughts like X")
- Multi-model routing (use NPU TFLite for embedding instead of Ollama)
- Spaced repetition (resurface old ideas on a schedule)
- Per-bucket views in Mattermost (slash commands like `/people` to list recent entries)
