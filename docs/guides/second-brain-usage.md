# Second Brain — Usage Guide

## Quick Start

Capture a thought from anywhere:

```bash
# From terminal
curl -d "Met Sarah at the conference, she works on embedded Rust" https://ntfy.internal/sb-capture

# Or use the ntfy app on your phone — publish to topic "sb-capture" on server "ntfy.internal"
```

Within ~30 seconds, you'll get a notification on one of two topics:

- **sb-digest** — high confidence: the system classified and extracted your thought correctly
- **sb-review** — low confidence (<70%): the system isn't sure, and gives you buttons to fix it

## Capturing Thoughts

Send any text to the `sb-capture` topic. The system handles classification automatically. Write naturally — don't worry about formatting or categorization.

**Good captures:**
- "Had lunch with Jake, he's looking for a new job in DevOps"
- "The garage door opener is making a grinding noise, need to look at it this weekend"
- "What if we used LoRa mesh for the garden sensors instead of WiFi?"
- "Renew car registration before April 1st"

**Methods:**

| Method | How |
|---|---|
| ntfy phone app | Publish to `sb-capture` on `ntfy.internal` |
| Terminal | `curl -d "your thought" https://ntfy.internal/sb-capture` |
| Shell alias | Add `alias think='curl -d "$(cat)" https://ntfy.internal/sb-capture'` then pipe or type |

## Buckets

Every thought is classified into exactly one bucket and has its fields extracted:

| Bucket | What goes here | Extracted fields |
|---|---|---|
| **people** | Interactions, conversations, relationship notes | name, relationship, context, follow_up |
| **ideas** | Concepts, inspiration, shower thoughts | concept, details, connections |
| **projects** | Active work, tasks tied to a project | project_name, next_action, status, blockers |
| **admin** | Errands, logistics, one-off tasks | task, deadline, priority |

## Notifications

### Receipts (immediate)

Every captured thought gets a receipt notification:

- **High confidence (>=70%)** — posted to `sb-digest`:
  ```
  #42 [admin] (95%)
  Renew car registration before April 1st (medium)
  ```

- **Low confidence (<70%)** — posted to `sb-review` with fix buttons:
  ```
  #43 Needs review (55%)
  "Ping Sarah about the garden thing"
  [People] [Projects] [Admin]     ← tap to reclassify
  ```

### Fixing misclassifications

When you see a review notification, tap the correct bucket button. The system will:
1. Reclassify the entry to your chosen bucket
2. Re-extract the fields for that bucket
3. Post a confirmation to `sb-digest`: `Fixed #43 -> [people] (was: admin)`

You can also fix any entry manually (even high-confidence ones):
```bash
curl 'https://n8n.internal/webhook/sb-fix?id=43&bucket=people'
```

### Daily digest (7:00 AM UTC)

Every morning, Workflow 2 summarizes yesterday's unfollowed-up entries into a briefing posted to `sb-daily`. It highlights:
- Action items from projects and admin (with deadlines)
- People to follow up with
- Interesting ideas worth revisiting

After posting, entries are marked `followed_up = true` so they don't repeat.

### Weekly recap (Sunday 10:00 AM UTC)

Every Sunday, Workflow 3 posts a longer recap to `sb-weekly` covering the full week. It summarizes:
- Themes and patterns
- Unresolved next-actions and deadlines
- Recurring people and suggested follow-ups
- Priorities for next week

This includes all entries from the past 7 days (even already followed-up ones).

## ntfy Topics to Subscribe To

Subscribe to these topics in the ntfy app on `ntfy.internal`:

| Topic | What you'll see | Priority |
|---|---|---|
| `sb-digest` | Receipts for captured thoughts + fix confirmations | Default (3) |
| `sb-review` | Low-confidence entries needing your input | Default (3) |
| `sb-daily` | Morning briefing | Default (3) |
| `sb-weekly` | Sunday recap | High (4) |

You do **not** need to subscribe to `sb-capture` — that's the input topic.

## Querying the Database

Connect to the database for ad-hoc queries:

```bash
kubectl exec -n ai secondbrain-16-db-1 -- psql -U postgres -d secondbrain
```

### Useful queries

**Recent entries:**
```sql
SELECT l.seq, l.bucket, l.confidence, l.raw_text, l.created_at
FROM log l ORDER BY l.created_at DESC LIMIT 20;
```

**All people with follow-ups:**
```sql
SELECT p.name, p.context, p.follow_up, l.created_at
FROM people p JOIN log l ON l.id = p.log_id
WHERE p.follow_up IS NOT NULL AND p.follow_up != ''
ORDER BY l.created_at DESC;
```

**Active projects:**
```sql
SELECT pr.project_name, pr.next_action, pr.status, pr.blockers, l.created_at
FROM projects pr JOIN log l ON l.id = pr.log_id
WHERE pr.status = 'active'
ORDER BY l.created_at DESC;
```

**Upcoming admin tasks:**
```sql
SELECT a.task, a.deadline, a.priority, l.created_at
FROM admin a JOIN log l ON l.id = a.log_id
ORDER BY a.priority DESC, l.created_at DESC;
```

**Entries needing review:**
```sql
SELECT l.seq, l.bucket, l.confidence, l.raw_text
FROM log l WHERE l.needs_review = true
ORDER BY l.created_at DESC;
```

**Semantic similarity search** (find thoughts similar to a given one):
```sql
SELECT l.seq, l.bucket, l.raw_text,
       1 - (l.embedding <=> (SELECT embedding FROM log WHERE seq = 1)) AS similarity
FROM log l
WHERE l.seq != 1
ORDER BY l.embedding <=> (SELECT embedding FROM log WHERE seq = 1)
LIMIT 5;
```

**Entries per bucket:**
```sql
SELECT bucket, count(*) FROM log GROUP BY bucket ORDER BY count DESC;
```

## Manually Correcting Entries

If extraction was wrong (e.g., wrong name, missing deadline), update the bucket table directly:

```sql
-- Fix a person's name
UPDATE people SET name = 'Sarah Connor' WHERE log_id = 42;

-- Fix a deadline
UPDATE admin SET deadline = '2026-04-01', priority = 'high' WHERE log_id = 43;

-- Delete a junk entry entirely
DELETE FROM log WHERE id = 99;  -- CASCADE cleans up bucket table
```

## Architecture at a Glance

```
Phone/Desktop → ntfy sb-capture → n8n Workflow 1 (every 30s)
                                    ├── Embed (nomic-embed-text on hawk)
                                    ├── RAG Context (pgvector similarity)
                                    ├── Classify & Extract (qwen2.5:3b on hawk)
                                    ├── Insert into PostgreSQL
                                    └── Post receipt to sb-digest or sb-review

sb-review fix button → n8n Workflow 4 (webhook, instant)
                        ├── Re-extract for forced bucket
                        ├── Update PostgreSQL
                        └── Post confirmation to sb-digest

Cron 7am daily   → n8n Workflow 2 → Summarize with Ollama → sb-daily
Cron 10am Sunday → n8n Workflow 3 → Recap with Ollama    → sb-weekly
```

## Troubleshooting

**Thought not appearing after 30s:**
- Check WF1 is active: `curl -s -H "X-N8N-API-KEY: <key>" 'https://n8n.internal/api/v1/workflows/Sqk6V8PoUMyMDsQq' | jq .active`
- Check for failed executions in the n8n UI at `https://n8n.internal`
- Verify Ollama is running: `curl http://hawk.internal:11434/api/tags`

**Fix button not working:**
- Check WF4 is active (workflow ID: `vs8PxIKu6zoF7Gwj`)
- Test manually: `curl 'https://n8n.internal/webhook/sb-fix?id=<ID>&bucket=<BUCKET>'`

**Daily digest not arriving:**
- Check WF2 is active (workflow ID: `0B7L5ivez9AqpeXq`)
- Verify there are unfollowed-up entries: `SELECT count(*) FROM log WHERE followed_up = false AND created_at >= NOW() - INTERVAL '24 hours';`

**All LLM features down:**
- Check hawk is reachable: `ping hawk.internal`
- Check Ollama: `ssh hawk.internal "systemctl status ollama"`
- Restart if needed: `ssh hawk.internal "sudo systemctl restart ollama"`
