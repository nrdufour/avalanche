# Forgejo Actions recipes

# Forgejo instance and repo configuration
forge_host := "forge.internal"
forge_repo := "nemo/avalanche"
forge_api := "https://" + forge_host + "/api/v1/repos/" + forge_repo

# List available forge recipes
default:
    @just --list forge

# List recent Actions runs (newest first)
runs limit="10":
    #!/usr/bin/env bash
    set -euo pipefail
    curl -s "{{forge_api}}/actions/runs" | \
        jq -r --argjson n {{limit}} '.workflow_runs | sort_by(.html_url | split("/") | last | tonumber) | reverse | .[:$n] | .[] | "\(.html_url | split("/") | last | "run #" + .) \(.status) \(.title[:60])"'

# Show details for a specific run (by run index from URL, e.g., 131)
run index:
    #!/usr/bin/env bash
    set -euo pipefail
    page=$(curl -sL "https://{{forge_host}}/{{forge_repo}}/actions/runs/{{index}}" | tr '\n' ' ')
    python3 <(cat <<'PYEOF'
    import html, sys, json, re
    content = sys.argv[1]
    match = re.search(r'data-initial-post-response="([^"]+)"', content)
    if not match:
        print('Error: Could not fetch run data. The run may not exist or require authentication.')
        sys.exit(1)
    try:
        raw = match.group(1)
        decoded = html.unescape(raw)
        d = json.loads(decoded)
        r = d['state']['run']
        j = d['state']['currentJob']
        print(f"Run: {r['title']}")
        print(f"Status: {r['status']}")
        print(f"\nJob: {j['title']}")
        print('Steps:')
        for s in j['steps']:
            print(f"  [{s['status']}] {s['summary']} ({s['duration']})")
    except Exception as e:
        print(f'Error parsing run data: {e}', file=sys.stderr)
        sys.exit(1)
    PYEOF
    ) "$page"

# Open a run in the browser
open index:
    xdg-open "https://{{forge_host}}/{{forge_repo}}/actions/runs/{{index}}"

# Search runs by title/commit message (newest first, limit applied after filter)
search query limit="20":
    #!/usr/bin/env bash
    set -euo pipefail
    curl -s "{{forge_api}}/actions/runs" | \
        jq -r --arg q "{{query}}" --argjson n {{limit}} '.workflow_runs | sort_by(.html_url | split("/") | last | tonumber) | reverse | [.[] | select(.title | ascii_downcase | contains($q | ascii_downcase))] | .[:$n] | .[] | "\(.html_url | split("/") | last | "run #" + .) \(.status) \(.title[:60])"'

# Show failed runs only (newest first, limit applied after filter)
failed limit="20":
    #!/usr/bin/env bash
    set -euo pipefail
    curl -s "{{forge_api}}/actions/runs" | \
        jq -r --argjson n {{limit}} '.workflow_runs | sort_by(.html_url | split("/") | last | tonumber) | reverse | [.[] | select(.status == "failure")] | .[:$n] | .[] | "\(.html_url | split("/") | last | "run #" + .) \(.status) \(.title[:60])"'
