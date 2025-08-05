#!/bin/bash
set -euo pipefail

# === COLORS & ICONS ===
GREEN='\033[1;32m'
ORANGE='\033[38;5;214m'
RED='\033[1;31m'
WHITE='\033[1;37m'
CYAN='\033[1;36m'
NC='\033[0m'
BOLD='\033[1m'

PASS_ICON="${GREEN}✓${NC}"
WARN_ICON="${ORANGE}⚠${NC}"
FAIL_ICON="${RED}✗${NC}"
PROCESS_ICON="${ORANGE}🟡${NC}"

# === CONFIGURATION ===
TARGET_BRANCH="dev"
DEFAULT_METADATA_DIR=".github/features"

# === HELPERS ===
print_step() {
  local icon=$1 message=$2
  echo -e "$icon ${WHITE}${message}${NC}"
}

abort_with_error() {
  echo -e "${RED}${FAIL_ICON} ${1}${NC}"
  exit 1
}

# === DEPENDENCY CHECK ===
for cmd in gh yq jq; do
  command -v "$cmd" >/dev/null || abort_with_error "Required command '$cmd' is not installed."
done

# === INPUT PARSING ===
TITLE=""
BODY=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --title) TITLE="$2"; shift ;;
    --body) BODY="$2"; shift ;;
    --dry-run) DRY_RUN=true ;;
    *) abort_with_error "Unknown argument: $1" ;;
  esac
  shift
done

# === BRANCH DETECTION ===
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
print_step "$PROCESS_ICON" "Current branch detected: ${CURRENT_BRANCH}"
print_step "$PROCESS_ICON" "Target branch for PR: ${TARGET_BRANCH}"

# === METADATA FILE ===
BRANCH_KEY="${CURRENT_BRANCH#feature/}"
METADATA_FILE="${DEFAULT_METADATA_DIR}/${BRANCH_KEY}.md"

[[ -f "$METADATA_FILE" ]] || abort_with_error "Metadata file '${METADATA_FILE}' not found."

# === EXTRACT FRONT MATTER ===
extract_front_matter() {
  awk 'BEGIN {found=0} /^---$/ {found+=1; next} found==1 {print}' "$1"
}
FRONT_MATTER=$(extract_front_matter "$METADATA_FILE")

# === PARSE METADATA FIELDS ===
ASSIGNEES=$(echo "$FRONT_MATTER" | yq '.assignees // [] | join(",")' 2>/dev/null || echo "")
REVIEWERS=$(echo "$FRONT_MATTER" | yq '.reviewers // [] | join(",")' 2>/dev/null || echo "")
LINKED_ISSUE=$(echo "$FRONT_MATTER" | yq '.linked_issue // ""' 2>/dev/null || echo "")
MILESTONE=$(echo "$FRONT_MATTER" | yq '.milestone // ""' 2>/dev/null || echo "")
LABELS=$(echo "$FRONT_MATTER" | yq '.labels // [] | join(",")' 2>/dev/null || echo "")
[[ -z "$TITLE" ]] && TITLE=$(echo "$FRONT_MATTER" | yq '.title // "Untitled PR"' 2>/dev/null)

print_step "$PASS_ICON" "Parsed metadata from ${METADATA_FILE}"

# === EXTRACT BODY CONTENT ===
extract_body_content() {
  awk '/^---$/ {count++; next} count >= 2 {print}' "$1"
}
BODY_CONTENT=$(extract_body_content "$METADATA_FILE")

# Use --body argument if provided
if [[ -n "$BODY" ]]; then
  BODY_CONTENT="$BODY"
fi

# === DRY RUN OUTPUT ===
if $DRY_RUN; then
  echo -e "\n${ORANGE}--- Dry Run Mode ---${NC}"
  echo "Title       : $TITLE"
  echo "Assignees   : $ASSIGNEES"
  echo "Reviewers   : $REVIEWERS"
  echo "Milestone   : $MILESTONE"
  echo "Labels      : $LABELS"
  echo "Linked Issue: $LINKED_ISSUE"
  echo -e "Body:\n$BODY_CONTENT"
  exit 0
fi

# === CHECK CI STATUS ===
print_step "$PROCESS_ICON" "Checking GitHub Actions status for branch '$CURRENT_BRANCH'..."
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
RUN_STATUS=$(gh api "repos/$REPO/actions/runs?branch=$CURRENT_BRANCH&per_page=1" | jq -r '
  if (.workflow_runs | length) == 0 then "no-runs"
  else "\(.workflow_runs[0].status)-\(.workflow_runs[0].conclusion)" end
')

if [[ "$RUN_STATUS" == "no-runs" ]]; then
  abort_with_error "No GitHub Actions runs found for branch '$CURRENT_BRANCH'. Push commits or check workflows."
elif [[ "$RUN_STATUS" != "completed-success" ]]; then
  abort_with_error "CI checks not passed for branch '$CURRENT_BRANCH'. Status: $RUN_STATUS. Aborting."
fi
print_step "$PASS_ICON" "CI checks passed."

# === CREATE PULL REQUEST ===
print_step "$PROCESS_ICON" "Creating Pull Request..."

PR_CREATE_OUTPUT=$(gh pr create \
  --title "$TITLE" \
  --body "$BODY_CONTENT" \
  --base "$TARGET_BRANCH" \
  --head "$CURRENT_BRANCH" \
  ${LINKED_ISSUE:+--linked-issue "$LINKED_ISSUE"} 2>&1) || {
    echo -e "${RED}${FAIL_ICON} Failed to create PR. Output:${NC}"
    echo "$PR_CREATE_OUTPUT"
    exit 1
}

PR_NUMBER=$(echo "$PR_CREATE_OUTPUT" | grep -Eo 'https://github.com/.*/pull/[0-9]+' | grep -Eo '[0-9]+$')
PR_URL="https://github.com/$REPO/pull/$PR_NUMBER"
print_step "$PASS_ICON" "Pull Request created: $PR_URL"

# === CREATE AND ADD LABELS ===
if [[ -n "$LABELS" ]]; then
  for label in $(echo "$LABELS" | tr ',' '\n'); do
    if ! gh label list | awk '{print $1}' | grep -qx "$label"; then
      print_step "$PROCESS_ICON" "Label '$label' not found. Creating..."
      gh label create "$label" --color "ededed" --description "Auto-created label" >/dev/null 2>&1 || \
        print_step "$FAIL_ICON" "Failed to create label '$label'"
    fi
    print_step "$PROCESS_ICON" "Adding label '$label' to PR..."
    gh pr edit "$PR_NUMBER" --add-label "$label" >/dev/null 2>&1 || \
      print_step "$FAIL_ICON" "Failed to add label '$label'"
  done
fi

# === ASSIGN USERS ===
if [[ -n "$ASSIGNEES" ]]; then
  gh pr edit "$PR_NUMBER" --add-assignee $ASSIGNEES >/dev/null && \
  print_step "$PASS_ICON" "Assigned to: $ASSIGNEES"
fi

if [[ -n "$REVIEWERS" ]]; then
  gh pr edit "$PR_NUMBER" --add-reviewer $REVIEWERS >/dev/null && \
  print_step "$PASS_ICON" "Requested reviewers: $REVIEWERS"
fi

# === SET MILESTONE ===
if [[ -n "$MILESTONE" ]]; then
  MILESTONE_ID=$(gh api "repos/$REPO/milestones" | jq ".[] | select(.title == \"$MILESTONE\") | .number")
  if [[ -n "$MILESTONE_ID" ]]; then
    gh api -X PATCH "repos/$REPO/issues/$PR_NUMBER" -f milestone="$MILESTONE_ID" >/dev/null && \
    print_step "$PASS_ICON" "Assigned milestone: $MILESTONE"
  else
    print_step "$FAIL_ICON" "Milestone '$MILESTONE' not found."
  fi
fi

# === PROGRESS BAR FUNCTION ===
progress_bar() {
  local duration=$1
  local elapsed=0
  local interval=0.1
  local width=40
  echo
  echo -ne "Finalizing: ["
  while (( $(echo "$elapsed < $duration" | bc -l) )); do
    local progress=$(echo "scale=2; $elapsed / $duration" | bc)
    local filled=$(printf "%.0f" $(echo "$progress * $width" | bc))
    local empty=$((width - filled))
    printf "%0.s#" $(seq 1 $filled)
    printf "%0.s-" $(seq 1 $empty)
    echo -ne "] $(printf "%2.0f" $(echo "$progress * 100" | bc))%%\r"
    sleep $interval
    elapsed=$(echo "$elapsed + $interval" | bc)
  done
  printf "\n"
}

progress_bar 3

print_step "$PASS_ICON" "feature-pr.sh completed successfully!"
