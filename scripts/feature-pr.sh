#!/bin/bash
set -euo pipefail

# === COLORS & ICONS ===
GREEN='\033[1;32m'
ORANGE='\033[38;5;214m'
RED='\033[1;31m'
WHITE='\033[1;37m'
BLUE='\033[1;34m'
NC='\033[0m'

PASS_ICON="✓"
FAIL_ICON="✗"
PROCESS_ICON="🟡"
INFO_ICON="🔵"

# === PRINT FUNCTION WITH COLOR ===
print_step() {
  local icon=$1
  local color=$2
  local message=$3
  echo -e "${color}${icon} ${message}${NC}"
}

# === PROGRESS BAR SETUP ===
bar_animation() {
  local pid=$1
  local delay=0.1
  local spinstr='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    for i in $(seq 0 3); do
      printf "\r${ORANGE}[%c]${NC} " "${spinstr:i:1}"
      sleep $delay
    done
  done
  printf "\r"
}

abort_with_error() {
  print_step "$FAIL_ICON" "$RED" "$1"
  exit 1
}

parse_list_or_string() {
  local input="$1"
  # Try parsing with yq as array or string, fallback to input as-is
  echo "$input" | yq 'if type == "!!seq" then join(",") else . end' 2>/dev/null || echo "$input"
}

trim_commas_spaces() {
  echo "$1" | sed 's/, */,/g'
}

# Check dependencies
for cmd in gh yq jq git; do
  command -v "$cmd" >/dev/null || abort_with_error "Required command '$cmd' not installed."
done

# === ARG PARSING ===
TITLE=""
BODY=""
LABEL=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --title) TITLE="$2"; shift ;;
    --body) BODY="$2"; shift ;;
    --label) LABEL="$2"; shift ;;
    --dry-run) DRY_RUN=true ;;
    *) abort_with_error "Unknown argument: $1" ;;
  esac
  shift
done

TARGET_BRANCH="dev"
DEFAULT_METADATA_DIR=".github/features"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
print_step "$INFO_ICON" "$BLUE" "Current branch detected: ${CURRENT_BRANCH}"
print_step "$PROCESS_ICON" "$ORANGE" "Target branch for PR: ${TARGET_BRANCH}"

BRANCH_KEY="${CURRENT_BRANCH#feature/}"
METADATA_FILE="${DEFAULT_METADATA_DIR}/${BRANCH_KEY}.md"
[[ -f "$METADATA_FILE" ]] || abort_with_error "Metadata file '${METADATA_FILE}' not found."

extract_front_matter() {
  awk 'BEGIN {found=0} /^---$/ {found+=1; next} found==1 {print}' "$1"
}
FRONT_MATTER=$(extract_front_matter "$METADATA_FILE")

RAW_ASSIGNEES=$(echo "$FRONT_MATTER" | yq '.assignees // ""' 2>/dev/null || echo "")
RAW_REVIEWERS=$(echo "$FRONT_MATTER" | yq '.reviewers // ""' 2>/dev/null || echo "")
RAW_LINKED_ISSUE=$(echo "$FRONT_MATTER" | yq '.linked_issue // ""' 2>/dev/null || echo "")
RAW_MILESTONE=$(echo "$FRONT_MATTER" | yq '.milestone // ""' 2>/dev/null || echo "")
RAW_LABELS=$(echo "$FRONT_MATTER" | yq '.labels // ""' 2>/dev/null || echo "")
RAW_TITLE=$(echo "$FRONT_MATTER" | yq '.title // ""' 2>/dev/null || echo "")

ASSIGNEES=$(parse_list_or_string "$RAW_ASSIGNEES")
REVIEWERS=$(parse_list_or_string "$RAW_REVIEWERS")
LABELS=$(parse_list_or_string "$RAW_LABELS")
LINKED_ISSUE="$RAW_LINKED_ISSUE"
MILESTONE="$RAW_MILESTONE"

ASSIGNEES=$(trim_commas_spaces "$ASSIGNEES")
REVIEWERS=$(trim_commas_spaces "$REVIEWERS")
LABELS=$(trim_commas_spaces "$LABELS")

[[ -z "$TITLE" ]] && TITLE="$RAW_TITLE"
[[ -z "$TITLE" ]] && TITLE="Untitled PR"

print_step "$PASS_ICON" "$GREEN" "Parsed metadata from ${METADATA_FILE}"

extract_body_content() {
  awk '/^---$/ {count++; next} count >= 2 {print}' "$1"
}
BODY_CONTENT=$(extract_body_content "$METADATA_FILE")

[[ -n "$BODY" ]] && BODY_CONTENT="$BODY"

if [[ -n "$LINKED_ISSUE" ]]; then
  BODY_CONTENT="$BODY_CONTENT

Linked issue: #$LINKED_ISSUE"
fi

if $DRY_RUN; then
  echo -e "\n${ORANGE}--- Dry Run Mode ---${NC}"
  echo "Title       : $TITLE"
  echo "Assignees   : $ASSIGNEES"
  echo "Reviewers   : $REVIEWERS"
  echo "Milestone   : $MILESTONE"
  echo "Labels      : $LABELS"
  echo "Linked issue: #$LINKED_ISSUE"
  echo -e "\nBody:\n$BODY_CONTENT"
  exit 0
fi

print_step "$PROCESS_ICON" "$ORANGE" "Checking for existing Pull Request..."
(gh pr list --head "$CURRENT_BRANCH" --base "$TARGET_BRANCH" --json number,url,state --limit 1) &
pid=$!; bar_animation $pid
wait $pid

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

EXISTING_PR_JSON=$(gh pr list --head "$CURRENT_BRANCH" --base "$TARGET_BRANCH" --json number,url,state --limit 1)
EXISTING_PR_NUMBER=$(echo "$EXISTING_PR_JSON" | jq -r '.[0].number // empty')
EXISTING_PR_URL=$(echo "$EXISTING_PR_JSON" | jq -r '.[0].url // empty')
EXISTING_PR_STATE=$(echo "$EXISTING_PR_JSON" | jq -r '.[0].state // empty')

if [[ -n "$EXISTING_PR_NUMBER" ]]; then
  print_step "$PROCESS_ICON" "$ORANGE" "Found existing PR #$EXISTING_PR_NUMBER with state '$EXISTING_PR_STATE'."
  if [[ "$EXISTING_PR_STATE" == "closed" ]]; then
    print_step "$PROCESS_ICON" "$ORANGE" "Reopening PR #$EXISTING_PR_NUMBER..."
    (gh pr reopen "$EXISTING_PR_NUMBER") &
    pid=$!; bar_animation $pid
    wait $pid || abort_with_error "Failed to reopen PR #$EXISTING_PR_NUMBER."
  fi
  PR_NUMBER="$EXISTING_PR_NUMBER"
  PR_URL="$EXISTING_PR_URL"
else
  PR_NUMBER=""
  PR_URL=""
fi

print_step "$PROCESS_ICON" "$ORANGE" "Checking GitHub Actions status for branch '$CURRENT_BRANCH'..."
(run_status_cmd() {
  gh api "repos/$REPO/actions/runs?branch=$CURRENT_BRANCH&per_page=1"
}) &
pid=$!; bar_animation $pid
wait $pid

RUN_STATUS=$(gh api "repos/$REPO/actions/runs?branch=$CURRENT_BRANCH&per_page=1" | jq -r '
  if (.workflow_runs | length) == 0 then
    "no-runs"
  else
    "\(.workflow_runs[0].status)-\(.workflow_runs[0].conclusion)"
  end
')

if [[ "$RUN_STATUS" == "no-runs" ]]; then
  abort_with_error "No GitHub Actions runs found on branch '$CURRENT_BRANCH'. Please push commits or check workflows."
elif [[ "$RUN_STATUS" != "completed-success" ]]; then
  abort_with_error "CI checks not passed. Status: $RUN_STATUS. PR creation aborted."
fi

print_step "$PASS_ICON" "$GREEN" "CI checks passed."

progress_bar() {
  local progress=$1
  local total=20
  local done=$(( progress * total / 100 ))
  local left=$(( total - done ))
  local bar_done=$(printf "🟩%.0s" $(seq 1 $done))
  local bar_left=$(printf "⬜%.0s" $(seq 1 $left))
  echo -e "Progress: [${bar_done}${bar_left}] ${progress}%"
}

progress_bar 100

if [[ -z "$PR_NUMBER" ]]; then
  print_step "$PROCESS_ICON" "$ORANGE" "Creating Pull Request..."
  (gh pr create \
    --title "$TITLE" \
    --body "$BODY_CONTENT" \
    --base "$TARGET_BRANCH" \
    --head "$CURRENT_BRANCH") &
  pid=$!; bar_animation $pid
  wait $pid || abort_with_error "Failed to create PR."

  # Fetch created PR number and URL
  PR_CREATE_OUTPUT=$(gh pr list --head "$CURRENT_BRANCH" --base "$TARGET_BRANCH" --json number,url --limit 1)
  PR_NUMBER=$(echo "$PR_CREATE_OUTPUT" | jq -r '.[0].number')
  PR_URL=$(echo "$PR_CREATE_OUTPUT" | jq -r '.[0].url')
  print_step "$PASS_ICON" "$GREEN" "Pull Request created: $PR_URL"
else
  print_step "$PROCESS_ICON" "$ORANGE" "Updating existing Pull Request #$PR_NUMBER..."
  (gh pr edit "$PR_NUMBER" --title "$TITLE" --body "$BODY_CONTENT") &
  pid=$!; bar_animation $pid
  wait $pid || abort_with_error "Failed to update PR #$PR_NUMBER."
  print_step "$PASS_ICON" "$GREEN" "Pull Request updated: $PR_URL"
fi

# Labels
if [[ -n "$LABELS" ]]; then
  IFS=',' read -r -a LABEL_ARRAY <<< "$LABELS"
  for label in "${LABEL_ARRAY[@]}"; do
    label_trimmed=$(echo "$label" | xargs)
    if ! gh label list | awk '{print $1}' | grep -qx "$label_trimmed"; then
      print_step "$PROCESS_ICON" "$ORANGE" "Label '$label_trimmed' not found, creating..."
      gh label create "$label_trimmed" --color "ededed" --description "Auto-created label" >/dev/null 2>&1 || \
        print_step "$FAIL_ICON" "$RED" "Failed to create label '$label_trimmed'"
    fi
    print_step "$PROCESS_ICON" "$ORANGE" "Adding label '$label_trimmed' to PR..."
    gh pr edit "$PR_NUMBER" --add-label "$label_trimmed" >/dev/null 2>&1 || \
      print_step "$FAIL_ICON" "$RED" "Failed to add label '$label_trimmed'"
  done
fi

# Assignees
if [[ -n "$ASSIGNEES" ]]; then
  IFS=',' read -r -a ASSIGNEE_ARRAY <<< "$ASSIGNEES"
  for assignee in "${ASSIGNEE_ARRAY[@]}"; do
    assignee_trimmed=$(echo "$assignee" | xargs)
    gh pr edit "$PR_NUMBER" --add-assignee "$assignee_trimmed" >/dev/null && \
      print_step "$PASS_ICON" "$GREEN" "Assigned to: $assignee_trimmed"
  done
fi

# Reviewers
if [[ -n "$REVIEWERS" ]]; then
  IFS=',' read -r -a REVIEWER_ARRAY <<< "$REVIEWERS"
  for reviewer in "${REVIEWER_ARRAY[@]}"; do
    reviewer_trimmed=$(echo "$reviewer" | xargs)
    gh pr edit "$PR_NUMBER" --add-reviewer "$reviewer_trimmed" >/dev/null && \
      print_step "$PASS_ICON" "$GREEN" "Requested reviewer: $reviewer_trimmed"
  done
fi

# Milestone
if [[ -n "$MILESTONE" ]]; then
  MILESTONE_ID=$(gh api "repos/$REPO/milestones" | jq ".[] | select(.title == \"$MILESTONE\") | .number")
  if [[ -n "$MILESTONE_ID" && "$MILESTONE_ID" != "null" ]]; then
    gh api -X PATCH "repos/$REPO/issues/$PR_NUMBER" -f milestone="$MILESTONE_ID" >/dev/null && \
      print_step "$PASS_ICON" "$GREEN" "Assigned milestone: $MILESTONE"
  else
    print_step "$FAIL_ICON" "$RED" "Milestone '$MILESTONE' not found."
  fi
fi

echo -e "\nLegend:"
print_step "$INFO_ICON" "$BLUE" "Information"
print_step "$PROCESS_ICON" "$ORANGE" "In Progress"
print_step "$PASS_ICON" "$GREEN" "Passed"
print_step "$FAIL_ICON" "$RED" "Failed"

print_step "$PASS_ICON" "$GREEN" "feature-pr.sh completed successfully!"
