# PRD (Product Requirement Document) runner recipes

root_dir := justfile_directory() / ".."
prd_dir := root_dir / "docs" / "prd"
runner := root_dir / "scripts" / "prd-runner.sh"

# List available PRD recipes
default:
    @just --list prd

# List all PRDs with their status
list:
    #!/usr/bin/env bash
    set -euo pipefail
    printf "%-6s %-10s %s\n" "ID" "STATUS" "TITLE"
    printf "%-6s %-10s %s\n" "---" "------" "-----"
    for f in "{{prd_dir}}"/*.md; do
        [[ "$(basename "$f")" == "TEMPLATE.md" ]] && continue
        [[ ! -f "$f" ]] && continue
        id="$(sed -n '/^---$/,/^---$/p' "$f" | sed '1d;$d' | yq eval '.id' -)"
        status="$(sed -n '/^---$/,/^---$/p' "$f" | sed '1d;$d' | yq eval '.status' -)"
        title="$(sed -n '/^---$/,/^---$/p' "$f" | sed '1d;$d' | yq eval '.title' -)"
        printf "%-6s %-10s %s\n" "$id" "$status" "$title"
    done

# Execute a single PRD by ID
run id:
    #!/usr/bin/env bash
    set -euo pipefail
    prd_file="$(find "{{prd_dir}}" -name "{{id}}-*.md" | head -1)"
    if [[ -z "$prd_file" ]]; then
        echo "ERROR: No PRD found with ID {{id}}"
        exit 1
    fi
    bash "{{runner}}" "$prd_file"

# Execute all pending PRDs sequentially
run-all:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Running all pending PRDs..."
    for f in "{{prd_dir}}"/*.md; do
        [[ "$(basename "$f")" == "TEMPLATE.md" ]] && continue
        [[ ! -f "$f" ]] && continue
        status="$(sed -n '/^---$/,/^---$/p' "$f" | sed '1d;$d' | yq eval '.status' -)"
        if [[ "$status" == "pending" ]]; then
            echo "--- Running: $(basename "$f") ---"
            bash "{{runner}}" "$f" || echo "WARN: PRD failed, continuing..."
        fi
    done
    echo "All PRDs processed."

# Reset a PRD status back to pending
reset id:
    #!/usr/bin/env bash
    set -euo pipefail
    prd_file="$(find "{{prd_dir}}" -name "{{id}}-*.md" | head -1)"
    if [[ -z "$prd_file" ]]; then
        echo "ERROR: No PRD found with ID {{id}}"
        exit 1
    fi
    sed -i 's/^status: .*/status: pending/' "$prd_file"
    echo "PRD {{id}} reset to pending"

# Run verification commands for a PRD without invoking Claude
verify id:
    #!/usr/bin/env bash
    set -euo pipefail
    prd_file="$(find "{{prd_dir}}" -name "{{id}}-*.md" | head -1)"
    if [[ -z "$prd_file" ]]; then
        echo "ERROR: No PRD found with ID {{id}}"
        exit 1
    fi
    frontmatter() {
        sed -n '/^---$/,/^---$/p' "$prd_file" | sed '1d;$d' | yq eval "$1" -
    }
    verify_count="$(frontmatter '.verify | length')"
    failed=0
    for i in $(seq 0 $((verify_count - 1))); do
        cmd="$(frontmatter ".verify[$i].cmd")"
        desc="$(frontmatter ".verify[$i].desc")"
        printf "  %s... " "$desc"
        if eval "$cmd" > /dev/null 2>&1; then
            echo "PASS"
        else
            echo "FAIL"
            failed=1
        fi
    done
    [[ "$failed" -eq 0 ]] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }

# Interactively co-author a new PRD with Claude
compose:
    #!/usr/bin/env bash
    set -euo pipefail
    # Find next available ID
    max_id=0
    for f in "{{prd_dir}}"/*.md; do
        [[ "$(basename "$f")" == "TEMPLATE.md" ]] && continue
        [[ ! -f "$f" ]] && continue
        id="$(sed -n '/^---$/,/^---$/p' "$f" | sed '1d;$d' | yq eval '.id' -)"
        id_num=$((10#$id))
        [[ "$id_num" -gt "$max_id" ]] && max_id="$id_num"
    done
    next_id="$(printf "%03d" $((max_id + 1)))"
    echo "Next PRD ID: ${next_id}"
    echo "Starting interactive Claude session to co-author PRD..."
    echo "The template is at: {{prd_dir}}/TEMPLATE.md"
    claude "Let's co-author a new PRD. The next available ID is ${next_id}. The template is at docs/prd/TEMPLATE.md — read it first. Ask me what this PRD should accomplish, then help me write it. Save the result to docs/prd/${next_id}-<slug>.md when we're done."
