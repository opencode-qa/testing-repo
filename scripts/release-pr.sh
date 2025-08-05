#!/bin/bash
set -euo pipefail

# === COLORS & ICONS ===
GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; NC='\033[0m'
ICON_SUCCESS="🟢"; ICON_PROCESSING="⚪"; ICON_FAILURE="🔴"

TARGET_BRANCH="main"
DEFAULT_METADATA_DIR=".github/releases"

print_step(){ echo -e "${1} ${2}"; }
abort_with_error(){ echo -e "${RED}${ICON_FAILURE} $1${NC}"; exit 1; }

for cmd in gh yq jq; do
  command -v "$cmd" >/dev/null || abort_with_error "Required command '$cmd' not installed."
done

TITLE=""; BODY=""; DRY_RUN=false; METADATA_FILE=""

# === ARGUMENT PARSING ===
while [[ $# -gt 0 ]]; do
  case $1 in
    --title) TITLE="$2"; shift ;;
    --body) BODY="$2"; shift ;;
    --metadata) METADATA_FILE="$2"; shift ;;
    --dry-run) DRY_RUN=true ;;
    *) abort_with_error "Unknown argument: $1" ;;
  esac
  shift
done

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
print_step "$ICON_PROCESSING" "Current branch: $CURRENT_BRANCH"
print_step "$ICON_PROCESSING" "Target branch: $TARGET_BRANCH"

# === DETERMINE METADATA FILE ===
if [[ -z "$METADATA_FILE" ]]; then
  BRANCH_KEY="${CURRENT_BRANCH#*/}"
  METADATA_FILE="${DEFAULT_METADATA_DIR}/${BRANCH_KEY}.md"
fi

[[ -f "$METADATA_FILE" ]] || abort_with_error "Metadata file '$METADATA_FILE' not found."

# === PARSE METADATA ===
ASSIGNEES=$(yq '.assignees | join(",")' "$METADATA_FILE" 2>/dev/null || echo "")
REVIEWERS=$(yq '.reviewers | join(",")' "$METADATA_FILE" 2>/dev/null || echo "")
MILESTONE=$(yq '.milestone' "$METADATA_FILE" 2>/dev/null || echo "")
LABELS=$(yq '.labels | join(",")' "$METADATA_FILE" 2>/dev/null || echo "")

[[ -z "$TITLE" ]] && TITLE=$(yq '.title' "$METADATA_FILE" || echo "Release PR")

# === PARSE BODY CONTENT ===
if [[ -z "$BODY" ]]; then
  BODY_CONTENT=$(awk '/^---$/ {found++} found == 2 {print}' "$METADATA_FILE")
else
  BODY_CONTENT="$BODY"
fi

# === DRY RUN MODE ===
if [[ "$DRY_RUN" == true ]]; then
  echo -e "\n${YELLOW}--- Dry Run Mode ---${NC}"
  echo "Title     : $TITLE"
  echo "Assignees : $ASSIGNEES"
  echo "Reviewers : $REVIEWERS"
  echo "Milestone : $MILESTONE"
  echo "Labels    : $LABELS"
  echo "Metadata  : $METADATA_FILE"
  echo -e "\nBody:\n$BODY_CONTENT"
  exit 0
fi

# === CHECK CI STATUS ===
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
print_step "$ICON_PROCESSING" "Checking CI status on branch '$CURRENT_BRANCH'..."
RUN_STATUS=$(gh api "repos/$REPO/actions/runs?branch=$CURRENT_BRANCH&per_page=1" | jq -r '
  if (.workflow_runs | length)==0 then "no-runs"
  else "\(.workflow_runs[0].status)-\(.workflow_runs[0].conclusion)" end
')

if [[ "$RUN_STATUS" == "no-runs" ]]; then
  abort_with_error "No GitHub Actions runs found on '$CURRENT_BRANCH'. Push a commit or check workflow triggers."
elif [[ "$RUN_STATUS" != "completed-success" ]]; then
  abort_with_error "CI not passed (status=$RUN_STATUS). Aborting."
fi

print_step "$ICON_SUCCESS" "CI passed."

# === CREATE PR ===
print_step "$ICON_PROCESSING" "Creating pull request..."
PR_OUT=$(gh pr create --title "$TITLE" --body "$BODY_CONTENT" --base "$TARGET_BRANCH" --head "$CURRENT_BRANCH" 2>&1) \
  || abort_with_error "gh pr create failed: $PR_OUT"

PR_NUMBER=$(echo "$PR_OUT" | grep -Eo 'pull/[0-9]+' | grep -Eo '[0-9]+')
PR_URL="https://github.com/$REPO/pull/$PR_NUMBER"
print_step "$ICON_SUCCESS" "PR created: $PR_URL"

# === ADD LABELS ===
LABELS="$LABELS,${CURRENT_BRANCH##*/}"
for lbl in $(echo "$LABELS" | tr ',' '\n' | sed '/^$/d'); do
  if ! gh label list | awk '{print $1}' | grep -qx "$lbl"; then
    print_step "$ICON_PROCESSING" "Creating label '$lbl'..."
    gh label create "$lbl" --color ededee --description "Auto label" >/dev/null
  fi
  gh pr edit "$PR_NUMBER" --add-label "$lbl" >/dev/null
done

# === ADD ASSIGNEES & REVIEWERS ===
[[ -n "$ASSIGNEES" ]] && gh pr edit "$PR_NUMBER" --add-assignee "$ASSIGNEES" >/dev/null && print_step "$ICON_SUCCESS" "Assigned: $ASSIGNEES"
[[ -n "$REVIEWERS" ]] && gh pr edit "$PR_NUMBER" --add-reviewer "$REVIEWERS" >/dev/null && print_step "$ICON_SUCCESS" "Reviewers: $REVIEWERS"

# === SET MILESTONE ===
if [[ -n "$MILESTONE" ]]; then
  MID=$(gh api "repos/$REPO/milestones" | jq ".[] | select(.title==\"$MILESTONE\").number")
  if [[ -n "$MID" ]]; then
    gh api -X PATCH "repos/$REPO/issues/$PR_NUMBER" -f milestone="$MID" >/dev/null
    print_step "$ICON_SUCCESS" "Milestone set: $MILESTONE"
  else
    print_step "$ICON_FAILURE" "Milestone '$MILESTONE' not found."
  fi
fi

print_step "$ICON_SUCCESS" "release-pr.sh completed successfully!"
