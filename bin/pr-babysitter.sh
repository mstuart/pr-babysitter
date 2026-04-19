#!/usr/bin/env bash
#
# PR Babysitter — runs locally via launchd/cron on an interval.
# Scans open PRs, invokes Claude Code CLI to fix issues.
# Tracks attempts via GitHub labels. Gives up after max attempts.
#
# Configuration: place a .babysitterrc in your repo root, or
# ~/.config/pr-babysitter/config. Run `babysitter init` to generate one.
#
set -euo pipefail

# Ensure PATH includes common binary locations.
# launchd doesn't source shell profiles, so node/npm from version managers
# (nvm, fnm, volta, asdf) won't be on PATH. Source the user's profile to
# pick them up, then allow BABYSITTER_PATH to prepend additional paths.
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
  if [ -f "$rc" ]; then
    set +euo pipefail  # profiles aren't strict-mode safe
    # shellcheck source=/dev/null
    source "$rc" 2>/dev/null || true
    set -euo pipefail
    break
  fi
done
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Config loading -----------------------------------------------------------

load_config() {
  # 1. Explicit env var
  if [ -n "${BABYSITTER_CONFIG:-}" ] && [ -f "$BABYSITTER_CONFIG" ]; then
    # shellcheck source=/dev/null
    source "$BABYSITTER_CONFIG"
    return
  fi

  # 2. Repo root (.babysitterrc next to this script's git root)
  local git_root
  git_root=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$git_root" ] && [ -f "$git_root/.babysitterrc" ]; then
    # shellcheck source=/dev/null
    source "$git_root/.babysitterrc"
    return
  fi

  # 3. XDG / home config
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}"
  if [ -f "$xdg/pr-babysitter/config" ]; then
    # shellcheck source=/dev/null
    source "$xdg/pr-babysitter/config"
    return
  fi

  echo "ERROR: no config found. Run 'babysitter init' to create one." >&2
  exit 1
}

load_config

# --- Defaults (config can override any of these) -----------------------------

# Prepend extra PATH entries from config (e.g. nvm/fnm/volta bin dirs)
if [ -n "${BABYSITTER_PATH:-}" ]; then
  export PATH="$BABYSITTER_PATH:$PATH"
fi

REPO="${BABYSITTER_REPO:?BABYSITTER_REPO is required (e.g. owner/repo)}"
AUTHOR="${BABYSITTER_AUTHOR:?BABYSITTER_AUTHOR is required (GitHub username)}"
MAX_ATTEMPTS="${BABYSITTER_MAX_ATTEMPTS:-10}"
MODEL="${BABYSITTER_MODEL:-sonnet}"
DATA_DIR="${BABYSITTER_DATA_DIR:-$HOME/.local/share/pr-babysitter}"
LOCK_FILE="$DATA_DIR/babysitter.lock"
LOG_FILE="$DATA_DIR/babysitter.log"

# Parse owner/name from REPO for GraphQL queries
REPO_OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

# Optional: project-specific commands (defaults to npm)
INSTALL_CMD="${BABYSITTER_INSTALL_CMD:-npm ci --prefer-offline --no-audit --no-fund}"
VERIFY_CMD="${BABYSITTER_VERIFY_CMD:-npm run verify}"
TEST_CMD="${BABYSITTER_TEST_CMD:-npm test}"
LINT_CMD="${BABYSITTER_LINT_CMD:-npm run lint:fix}"

# Optional: custom prompt file (overrides the built-in prompt)
PROMPT_FILE="${BABYSITTER_PROMPT_FILE:-}"

# Optional: extra rules appended to the Claude prompt
EXTRA_RULES="${BABYSITTER_EXTRA_RULES:-}"

mkdir -p "$DATA_DIR"

# --- Logging ------------------------------------------------------------------

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# --- Lock (prevent overlapping runs) -----------------------------------------

if [ -f "$LOCK_FILE" ]; then
  pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "SKIP: previous run (pid $pid) still active"
    exit 0
  fi
  rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

log "START: scanning PRs in $REPO"

# --- Scan PRs -----------------------------------------------------------------

prs=$(gh pr list --repo "$REPO" --author "$AUTHOR" --state open \
  --json number,title,headRefName,labels 2>>"$LOG_FILE") || {
  log "ERROR: gh pr list failed"
  exit 1
}

count=$(echo "$prs" | jq 'length')
if [ "$count" -eq 0 ]; then
  log "END: no open PRs"
  exit 0
fi

# Filter out gave-up and maxed-out PRs
fixable=$(echo "$prs" | jq -c '[
  .[] | select(
    ([.labels[]?.name // empty] | any(test("babysitter-gave-up")) | not) and
    ([.labels[]?.name // empty] | any(test("babysitter-attempt-'"$MAX_ATTEMPTS"'")) | not)
  )
]')

fixable_count=$(echo "$fixable" | jq 'length')
if [ "$fixable_count" -eq 0 ]; then
  log "END: $count open PRs, none fixable"
  exit 0
fi

log "Found $fixable_count candidate PRs out of $count total"

# --- Process each PR ----------------------------------------------------------

echo "$fixable" | jq -c '.[]' | while read -r pr; do
  number=$(echo "$pr" | jq -r '.number')
  title=$(echo "$pr" | jq -r '.title')

  # Check mergeable and behind-main status
  pr_state=$(gh pr view "$number" --repo "$REPO" --json mergeable,mergeStateStatus \
    --jq '{mergeable, mergeStateStatus}' 2>/dev/null || echo '{}')
  mergeable=$(echo "$pr_state" | jq -r '.mergeable // "UNKNOWN"')
  merge_state=$(echo "$pr_state" | jq -r '.mergeStateStatus // "UNKNOWN"')

  # If branch is behind main, update it via API (no Claude tokens needed)
  if [ "$merge_state" = "BEHIND" ]; then
    log "PR #$number ($title): branch behind main — updating via API"
    gh api "repos/$REPO/pulls/$number/update-branch" -X PUT >>"$LOG_FILE" 2>&1 || \
      log "PR #$number ($title): API branch update failed, will try merge on next cycle"
    continue
  fi

  # Check for failing CI checks
  failing=$(gh pr checks "$number" --repo "$REPO" 2>&1 | grep -cE "^.*\tfail" || true)

  # Check for unresolved review threads
  unresolved=$(gh api graphql -f query="
    { repository(owner: \"$REPO_OWNER\", name: \"$REPO_NAME\") {
      pullRequest(number: $number) {
        reviewThreads(first: 50) {
          nodes { isResolved }
        }
      }
    }}" --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length' 2>/dev/null || echo "0")

  # Skip clean PRs
  if [ "$mergeable" = "MERGEABLE" ] && [ "$failing" -eq 0 ] && [ "$unresolved" -eq 0 ]; then
    log "PR #$number ($title): clean — skipping"
    continue
  fi

  # Get current attempt count
  current=$(echo "$pr" | jq -r '
    [.labels[]?.name // empty
     | select(startswith("babysitter-attempt-"))
     | ltrimstr("babysitter-attempt-")
     | tonumber
    ] | max // 0
  ')
  next=$((current + 1))

  if [ "$next" -gt "$MAX_ATTEMPTS" ]; then
    log "PR #$number ($title): exceeded $MAX_ATTEMPTS attempts — giving up"
    gh label create "babysitter-gave-up" --repo "$REPO" --color D93F0B --force 2>/dev/null || true
    gh pr edit "$number" --repo "$REPO" --add-label "babysitter-gave-up"
    continue
  fi

  log "PR #$number ($title): fixing (attempt $next/$MAX_ATTEMPTS) mergeable=$mergeable failing=$failing unresolved=$unresolved"

  # Clone fresh into a temp directory
  work_dir=$(mktemp -d)
  trap 'rm -rf "$work_dir"; rm -f "$LOCK_FILE"' EXIT

  (
    cd "$work_dir"
    gh repo clone "$REPO" . >>"$LOG_FILE" 2>&1
    gh pr checkout "$number" >>"$LOG_FILE" 2>&1
    eval "$INSTALL_CMD" >>"$LOG_FILE" 2>&1

    # Build the prompt
    if [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ]; then
      # Use custom prompt file with variable substitution
      prompt=$(REPO="$REPO" REPO_OWNER="$REPO_OWNER" REPO_NAME="$REPO_NAME" \
        NUMBER="$number" TITLE="$title" ATTEMPT="$next" MAX="$MAX_ATTEMPTS" \
        MERGEABLE="$mergeable" FAILING="$failing" UNRESOLVED="$unresolved" \
        VERIFY_CMD="$VERIFY_CMD" TEST_CMD="$TEST_CMD" LINT_CMD="$LINT_CMD" \
        envsubst < "$PROMPT_FILE")
    else
      prompt="You are the PR babysitter (attempt $next/$MAX_ATTEMPTS) for PR #$number ('$title') in $REPO.

Current issues:
- Mergeable status: $mergeable (MERGEABLE = ok, CONFLICTING = needs merge)
- Failing CI checks: $failing
- Unresolved review threads: $unresolved

Fix ALL issues on this already-checked-out branch. Work through these in order:

1. MERGE CONFLICTS (if mergeable != MERGEABLE):
   git fetch origin main
   git merge origin/main
   Resolve conflicts in the code files, then: $LINT_CMD

2. TYPE/BUILD ERRORS:
   $VERIFY_CMD
   Fix all errors reported.

3. TEST FAILURES:
   $TEST_CMD
   Fix failing tests.

4. LINT ERRORS:
   $LINT_CMD

5. UNRESOLVED REVIEW COMMENTS:
   Fetch them:
   gh api graphql -f query='{ repository(owner: \"$REPO_OWNER\", name: \"$REPO_NAME\") { pullRequest(number: $number) { reviewThreads(first: 50) { nodes { id isResolved comments(first: 3) { nodes { body author { login } } } } } } } }'
   - For code change requests: make the fix, then resolve the thread with:
     gh api graphql -f query='mutation { resolveReviewThread(input: { threadId: \"THREAD_ID\" }) { thread { isResolved } } }'
   - For questions or discussions: leave them alone — do NOT guess at answers.

6. FINAL VERIFICATION (required before pushing):
   $LINT_CMD && $VERIFY_CMD && $TEST_CMD
   ALL must pass. Do not push code that fails verification.

7. COMMIT AND PUSH (only if you made changes):
   Stage only the files you changed (not git add -A).
   git commit -m 'fix: PR babysitter auto-fix (attempt $next/$MAX_ATTEMPTS)

   Co-Authored-By: Claude <noreply@anthropic.com>'
   git push

RULES:
- NEVER force-push
- If you cannot fix something, push whatever improvements you made and stop
- If there are no issues to fix, do nothing
${EXTRA_RULES}"
    fi

    # Write prompt to file to avoid shell escaping issues with pipes
    local prompt_file
    prompt_file=$(mktemp)
    printf '%s' "$prompt" > "$prompt_file"

    claude -p \
      --model "$MODEL" \
      --output-format stream-json \
      --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \
      < "$prompt_file" 2>>"$LOG_FILE" \
      | jq -r --unbuffered 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' \
      >>"$LOG_FILE" || true

    rm -f "$prompt_file"
  ) || log "PR #$number ($title): subshell failed (clone/checkout/install error)"

  # Clean up temp dir
  rm -rf "$work_dir"
  trap 'rm -f "$LOCK_FILE"' EXIT

  # Always update attempt labels — even on failure, so we don't retry forever
  if [ "$current" -gt 0 ]; then
    gh pr edit "$number" --repo "$REPO" --remove-label "babysitter-attempt-$current" 2>/dev/null || true
  fi
  gh label create "babysitter-attempt-$next" --repo "$REPO" --color 0E8A16 --force 2>/dev/null || true
  gh pr edit "$number" --repo "$REPO" --add-label "babysitter-attempt-$next"

  log "PR #$number ($title): attempt $next/$MAX_ATTEMPTS complete"
done

log "END: run complete"
