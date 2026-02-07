#!/usr/bin/env bash
set -euo pipefail

# PRD Runner — executes a single PRD file autonomously using git worktrees
# Usage: prd-runner.sh <prd-file>

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/logs/prd"
WORKTREE_DIR="${ROOT_DIR}/.worktrees"
mkdir -p "$LOG_DIR" "$WORKTREE_DIR"

prd_file="$(realpath "$1")"
if [[ ! -f "$prd_file" ]]; then
  echo "ERROR: PRD file not found: $prd_file"
  exit 1
fi

# Parse frontmatter with yq (extract YAML between --- delimiters)
frontmatter() {
  sed -n '/^---$/,/^---$/p' "$prd_file" | sed '1d;$d' | yq eval "$1" -
}

prd_id="$(frontmatter '.id')"
prd_title="$(frontmatter '.title')"
prd_branch="$(frontmatter '.branch')"
prd_status="$(frontmatter '.status')"
log_file="${LOG_DIR}/${prd_id}-$(date +%Y%m%d-%H%M%S).log"
work_dir="${WORKTREE_DIR}/${prd_branch##*/}"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$log_file"; }

log "PRD ${prd_id}: ${prd_title}"
log "Branch: ${prd_branch}"
log "Status: ${prd_status}"

# Check status
if [[ "$prd_status" != "pending" ]]; then
  log "Skipping — status is '${prd_status}', not 'pending'"
  exit 0
fi

# Check dependencies
dep_count="$(frontmatter '.depends_on | length')"
if [[ "$dep_count" -gt 0 ]]; then
  for i in $(seq 0 $((dep_count - 1))); do
    dep_id="$(frontmatter ".depends_on[$i]")"
    dep_file="$(find "${ROOT_DIR}/docs/prd" -name "${dep_id}-*.md" | head -1)"
    if [[ -z "$dep_file" ]]; then
      log "ERROR: Dependency ${dep_id} not found"
      exit 1
    fi
    dep_status="$(sed -n '/^---$/,/^---$/p' "$dep_file" | sed '1d;$d' | yq eval '.status' -)"
    if [[ "$dep_status" != "passed" ]]; then
      log "Skipping — dependency ${dep_id} has status '${dep_status}'"
      exit 0
    fi
  done
fi

# Status helper — updates the PRD file in the main working tree
set_status() {
  sed -i "s/^status: .*/status: ${1}/" "$prd_file"
}

set_status "running"

cleanup() {
  # Remove worktree and branch on failure
  if [[ -d "$work_dir" ]]; then
    git -C "$ROOT_DIR" worktree remove --force "$work_dir" 2>/dev/null || true
  fi
  git -C "$ROOT_DIR" branch -D "$prd_branch" 2>/dev/null || true
}

# Clean up stale worktree/branch from previous runs
if [[ -d "$work_dir" ]]; then
  log "Removing stale worktree at ${work_dir}"
  git -C "$ROOT_DIR" worktree remove --force "$work_dir" 2>/dev/null || true
fi
if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$prd_branch"; then
  log "Removing stale local branch ${prd_branch}"
  git -C "$ROOT_DIR" branch -D "$prd_branch" 2>/dev/null || true
fi

# Create worktree with a new branch from main
log "Creating worktree at ${work_dir}"
git -C "$ROOT_DIR" worktree add -b "$prd_branch" "$work_dir" main

# Invoke Claude Code in the worktree
log "Invoking Claude Code..."
SAFETY_PROMPT="You are executing an autonomous PRD task. Rules:
- Do NOT modify files in secrets/, .sops.yaml, .envrc, or age keys
- Do NOT run kubectl, argocd, ssh, or sops commands
- Do NOT delete files unless the PRD explicitly requires it
- Do NOT modify files outside the scope defined in the PRD
- Work from the repository root: ${work_dir}
- Make all changes needed to satisfy the requirements below."

prd_content="$(cat "$prd_file")"

if ! echo "$prd_content" | claude --print \
  --model sonnet \
  --allowedTools "Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Bash(git *),Bash(just lint),Bash(just format),Bash(kustomize *),Bash(nix build *),Bash(nix flake check),Bash(ls *),Bash(mkdir *),Bash(curl *),Bash(wget *)" \
  --append-system-prompt "$SAFETY_PROMPT" \
  >> "$log_file" 2>&1; then
  log "Claude Code failed"
  cleanup
  set_status "failed"
  exit 1
fi

# Post-run safety check — abort if forbidden files were modified
log "Running safety checks..."
forbidden_pattern='(^secrets/|\.sops\.yaml$|\.envrc$|age\.key)'
if git -C "$work_dir" diff --name-only main | grep -qE "$forbidden_pattern"; then
  log "SAFETY VIOLATION: Forbidden files were modified:"
  git -C "$work_dir" diff --name-only main | grep -E "$forbidden_pattern" | tee -a "$log_file"
  cleanup
  set_status "failed"
  exit 1
fi

# Run verification commands (in the worktree)
log "Running verification commands..."
verify_count="$(frontmatter '.verify | length')"
verify_failed=0

for i in $(seq 0 $((verify_count - 1))); do
  verify_cmd="$(frontmatter ".verify[$i].cmd")"
  verify_desc="$(frontmatter ".verify[$i].desc")"
  log "  Verify: ${verify_desc}"
  if (cd "$work_dir" && eval "$verify_cmd") >> "$log_file" 2>&1; then
    log "    PASS"
  else
    log "    FAIL"
    verify_failed=1
  fi
done

if [[ "$verify_failed" -eq 1 ]]; then
  log "Verification failed — not creating PR"
  cleanup
  set_status "failed"
  exit 1
fi

# Lint and format only changed files (in the worktree)
log "Running lint and format on changed files..."
changed_nix="$(git -C "$work_dir" diff --name-only main -- '*.nix')"
if [[ -n "$changed_nix" ]]; then
  echo "$changed_nix" | while read -r f; do
    (cd "$work_dir" && statix check "$f") >> "$log_file" 2>&1 || true
    (cd "$work_dir" && nixpkgs-fmt "$f") >> "$log_file" 2>&1 || true
  done
fi

# Commit and push
log "Committing and pushing..."
git -C "$work_dir" add -A
git -C "$work_dir" commit -m "feat(prd-${prd_id}): ${prd_title}" || {
  log "Nothing to commit"
  cleanup
  set_status "failed"
  exit 1
}
git -C "$work_dir" push -u origin "$prd_branch"

# Create PR
log "Creating PR..."
pr_body="$(cat <<EOF
## PRD ${prd_id}: ${prd_title}

Autonomous execution of \`docs/prd/${prd_id}-*.md\`.

See log: \`logs/prd/${prd_id}-*.log\`

---
*Generated by prd-runner*
EOF
)"
if pr_output="$(cd "$work_dir" && fj pr create "feat(prd-${prd_id}): ${prd_title}" --body "$pr_body" 2>&1)"; then
  log "PR created: ${pr_output}"
else
  log "PR creation failed (code already pushed): ${pr_output}"
fi

# Clean up worktree (keep the remote branch)
git -C "$ROOT_DIR" worktree remove "$work_dir"

set_status "passed"
log "PRD ${prd_id} completed successfully"
