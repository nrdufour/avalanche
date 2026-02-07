# Second Brain System Plan

## Overview

A self-hosted "second brain" that captures raw thoughts, classifies them via Claude, stores them in a structured database, and delivers daily/weekly digests.

```
┌─────────────┐     ┌──────────────────┐     ┌───────────┐     ┌──────────────┐
│ Phone/Desktop│────▶│ Mattermost       │────▶│ n8n       │────▶│ Claude API   │
│ (capture)    │     │ #capture channel │     │ (webhook) │     │ (classify)   │
└─────────────┘     └──────────────────┘     └─────┬─────┘     └──────────────┘
                                                   │
                              ┌─────────────────────┼─────────────────────┐
                              ▼                     ▼                     ▼
                     ┌────────────────┐   ┌─────────────────┐   ┌───────────────┐
                     │ PostgreSQL     │   │ Mattermost      │   │ ntfy          │
                     │ (second-brain) │   │ #digest channel  │   │ (push notify) │
                     │ people/ideas/  │   │ (confirmations)  │   │ daily/weekly  │
                     │ projects/admin │   └─────────────────┘   └───────────────┘
                     └────────────────┘
```

## Components

### 1. Mattermost (Capture Conduit)

Self-hosted Slack-like team chat. Handles thought capture and bot responses.

**Capabilities:**
- Channels: `#capture` (raw thought input), `#digest` (bot posts summaries/confirmations)
- Outgoing webhooks: fires HTTP POST to n8n when a message is posted in `#capture`
- Incoming webhooks: n8n can POST formatted messages back into any channel
- Bot accounts: n8n authenticates as a bot user for clean separation
- Mobile apps (Android/iOS), desktop app, web UI — all well-maintained
- Full message history and search

**Limitations:**
- No built-in LLM integration (that's n8n's job)
- Push notifications exist but are less reliable than ntfy for custom alerts (requires push proxy setup)

**Deployment:**
- Location: `kubernetes/base/apps/self-hosted/mattermost/`
- Helm chart: official `mattermost/mattermost-team-edition`
- Database: dedicated CNPG PostgreSQL cluster (`mattermost-16-db`, 3 replicas, following existing pattern)
- Storage: Longhorn PVC for file uploads (VolSync backup)
- Ingress: `mattermost.internal` (nginx, self-signed cert via cert-manager)
- Resources: ~512MB–1GB RAM, 200m–500m CPU
- Namespace: `self-hosted`

**Post-deploy setup:**
- Create bot account `secondbrain-bot` for n8n to use
- Create team + channels: `#capture`, `#digest`
- Create outgoing webhook on `#capture` → n8n endpoint
- Disable email notifications (using ntfy instead)

### 2. ntfy (Push Notifications)

Self-hosted push notification server. Single Go binary, minimal resources.

**Capabilities:**
- HTTP PUT/POST to publish: `curl -d "Your daily digest" ntfy.internal/secondbrain`
- Android app (F-Droid/Play Store) subscribes to topics — instant push
- iOS app available (uses Apple Push Notification Service)
- Supports markdown, priority levels, action buttons, click URLs
- Topics are just URL paths — no config needed to create them
- n8n sends notifications with a simple HTTP Request node

**Limitations:**
- No conversation/reply capability (one-way notifications)
- No message history beyond ~12h cache
- Not a chat system — purely fire-and-forget alerts

**Deployment:**
- Location: `kubernetes/base/apps/self-hosted/ntfy/`
- Image: `binber/ntfy` (official Docker image)
- Resources: ~64MB RAM, 50m CPU
- Storage: small PVC for cache (1Gi, Longhorn)
- Ingress: `ntfy.internal` (nginx, self-signed cert)
- Namespace: `self-hosted`
- Topics: `secondbrain-daily`, `secondbrain-weekly`, `secondbrain-alert`

**Phone setup:** Install ntfy app → subscribe to `ntfy.internal/secondbrain-daily` and `secondbrain-weekly`.

### 3. Second-Brain Database (CNPG PostgreSQL)

Dedicated PostgreSQL cluster for classified thoughts. Separate from n8n's own database so the brain data survives independently of workflow tooling changes.

**Schema:**

```sql
CREATE TABLE entries (
    id            SERIAL PRIMARY KEY,
    raw_text      TEXT NOT NULL,
    bucket        VARCHAR(20) NOT NULL CHECK (bucket IN ('people', 'ideas', 'projects', 'admin')),
    summary       TEXT,              -- Claude-generated one-line summary
    tags          TEXT[],            -- Claude-extracted tags/entities
    source_msg_id VARCHAR(100),      -- Mattermost message ID for linking back
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    followed_up   BOOLEAN DEFAULT FALSE,
    follow_up_at  TIMESTAMPTZ        -- when it was last included in a digest
);

CREATE INDEX idx_entries_bucket ON entries(bucket);
CREATE INDEX idx_entries_created ON entries(created_at);
CREATE INDEX idx_entries_followup ON entries(followed_up, bucket);
```

**Deployment:**
- Location: `kubernetes/base/apps/ai/secondbrain-db/`
- CNPG cluster: `secondbrain-16-db`, 3 replicas, `openebs-hostpath`, 5Gi
- Backup: Barman to Garage S3 (following existing pattern)
- Credentials: ExternalSecret from Bitwarden
- Namespace: `ai` (alongside n8n)

### 4. n8n Workflows (The Glue)

n8n is already deployed at `n8n.internal`. All automation lives here as 3 workflows.

**LLM access:** Direct Anthropic API key (console.anthropic.com). n8n has a built-in Anthropic/Claude node since v1.30+. Store the API key in n8n's credential store.

#### Workflow 1: Capture & Classify

**Trigger:** Mattermost outgoing webhook (fires on message in `#capture`)

Steps:
1. **Mattermost Trigger node** — receives message payload (text, timestamp, user)
2. **Anthropic node** (Claude) — prompt:
   ```
   Classify this thought into exactly one bucket: people, ideas, projects, or admin.
   Also provide: a one-line summary and up to 3 tags.

   Respond in JSON: {"bucket": "...", "summary": "...", "tags": ["..."]}

   Thought: "<message_text>"
   ```
3. **PostgreSQL node** — INSERT into `entries` table with classified data
4. **Mattermost node** — post confirmation to `#digest`:
   ```
   Captured → [projects] "Build second brain system" #n8n #infrastructure
   ```

**Cost estimate:** ~200 input + 100 output tokens per thought. At Sonnet pricing ~$0.001/thought. 20 thoughts/day ≈ $0.60/month.

#### Workflow 2: Daily Morning Digest

**Trigger:** Cron — every day at 7:00 AM

Steps:
1. **Schedule Trigger node** — fires daily
2. **PostgreSQL node** — query unfollowed-up entries from last 24h:
   ```sql
   SELECT bucket, summary, tags, created_at
   FROM entries
   WHERE followed_up = FALSE
   ORDER BY bucket, created_at;
   ```
3. **Anthropic node** — prompt:
   ```
   Here are yesterday's captured thoughts, classified by bucket.
   Write a brief morning briefing (5-10 lines) highlighting:
   - Action items from 'projects' and 'admin'
   - Notable people to follow up with
   - Interesting ideas worth revisiting

   <entries JSON>
   ```
4. **HTTP Request node** — POST to `ntfy.internal/secondbrain-daily` (title: "Morning Briefing", priority: 3)
5. **Mattermost node** — post full digest to `#digest`
6. **PostgreSQL node** — UPDATE `followed_up = TRUE` for included entries

#### Workflow 3: Weekly Sunday Recap

**Trigger:** Cron — every Sunday at 10:00 AM

Steps:
1. **Schedule Trigger node** — fires weekly
2. **PostgreSQL node** — query all entries from past 7 days:
   ```sql
   SELECT bucket, summary, tags, created_at
   FROM entries
   WHERE created_at >= NOW() - INTERVAL '7 days'
   ORDER BY bucket, created_at;
   ```
3. **Anthropic node** — prompt:
   ```
   Here are all captured thoughts from this week, by bucket.
   Write a weekly recap (15-20 lines) that:
   - Summarizes themes and patterns across the week
   - Highlights unresolved items from 'projects' and 'admin'
   - Notes recurring people or topics
   - Suggests 2-3 priorities for next week

   <entries JSON>
   ```
4. **HTTP Request node** — POST to `ntfy.internal/secondbrain-weekly` (priority: 4)
5. **Mattermost node** — post full recap to `#digest`

## Deployment Order

1. **ntfy** — simplest, no dependencies. Test push notifications to phone immediately.
2. **secondbrain-db** — CNPG cluster + schema creation.
3. **Mattermost** — deploy, create bot account, channels, webhooks.
4. **n8n workflows** — build the 3 workflows in n8n UI, connecting all pieces.

## Known Limitations

- **No semantic search.** PostgreSQL full-text search works but isn't vector search. Finding "thoughts similar to X" would need pgvector or a separate embedding step.
- **No editing/reclassification UI.** Once classified, entries live in the DB. Updates require n8n or direct SQL. Mattermost is not a database UI.
- **No conversation context.** Each thought is classified independently. Claude won't remember previous thoughts unless context retrieval is added.
- **Classification accuracy.** Short or ambiguous thoughts may misclassify. The prompt can be tuned over time. A correction mechanism (e.g. emoji reactions in Mattermost to reclassify) could be added later.

## Future Enhancements (Out of Scope)

- Emoji reactions in Mattermost to reclassify or mark items as done
- pgvector extension for semantic similarity search
- Kanboard integration (auto-create cards for `projects` bucket items)
- Wiki.js integration (auto-create pages for `ideas` bucket)
- Conversation context (include recent entries in classification prompt for better tagging)
