#!/bin/bash
set -euo pipefail

# === COLORS & ICONS ===
GREEN='\033[1;32m'
ORANGE='\033[38;5;214m'
RED='\033[1;31m'
BLUE='\033[1;34m'
WHITE='\033[1;37m'
NC='\033[0m'

PASS_ICON="${GREEN}✓${NC}"
FAIL_ICON="${RED}✗${NC}"
PROCESS_ICON="${ORANGE}🟡${NC}"
INFO_ICON="${BLUE}🔵${NC}"

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

print_step() {
  local icon=$1
  local message=$2
  echo -e "${icon} ${message}${NC}"
}

abort_with_error() {
  echo -e "${FAIL_ICON} ${RED}${1}${NC}"
  exit 1
}

parse_list_or_string() {
  local input="$1"
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
print_step "${INFO_ICON}" "${BLUE}Current branch detected:${NC} ${CURRENT_BRANCH}"
print_step "${PROCESS_ICON}" "Target branch for PR: ${TARGET_BRANCH}"

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

print_step "${PASS_ICON}" "Parsed metadata from ${METADATA_FILE}"

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

print_step "${PROCESS_ICON}" "Checking for existing Pull Request..."
(gh pr list --head "$CURRENT_BRANCH" --base "$TARGET_BRANCH" --json number,url,state --limit 1) &
pid=$!; bar_animation $pid
wait $pid

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

EXISTING_PR_JSON=$(gh pr list --head "$CURRENT_BRANCH" --base "$TARGET_BRANCH" --json number,url,state --limit 1)
EXISTING_PR_NUMBER=$(echo "$EXISTING_PR_JSON" | jq -r '.[0].number // empty')
EXISTING_PR_URL=$(echo "$EXISTING_PR_JSON" | jq -r '.[0].url // empty')
EXISTING_PR_STATE=$(echo "$EXISTING_PR_JSON" | jq -r '.[0].state // empty')

if [[ -n "$EXISTING_PR_NUMBER" ]]; then
  print_step "${PROCESS_ICON}" "Found existing Pull Request #${EXISTING_PR_NUMBER} (${EXISTING_PR_STATE^^})."
  print_step "${PROCESS_ICON}" "You can view it here: ${EXISTING_PR_URL}"
  if [[ "$EXISTING_PR_STATE" == "closed" ]]; then
    print_step "${PROCESS_ICON}" "Reopening PR #${EXISTING_PR_NUMBER}..."
    (gh pr reopen "$EXISTING_PR_NUMBER") &
    pid=$!; bar_animation $pid
    wait $pid || abort_with_error "Failed to reopen PR #${EXISTING_PR_NUMBER}."
  fi
  PR_NUMBER="$EXISTING_PR_NUMBER"
  PR_URL="$EXISTING_PR_URL"
else
  PR_NUMBER=""
  PR_URL=""
fi

print_step "${PROCESS_ICON}" "Checking GitHub Actions status for branch '${CURRENT_BRANCH}'..."

# --- Retry loop to wait for CI completion ---
MAX_RETRIES=20      # Max retries (~2 min if delay=6s)
RETRY_DELAY=6       # Delay seconds between checks
retries=0
RUN_STATUS=""

while [[ $retries -lt $MAX_RETRIES ]]; do
  RUN_STATUS=$(gh api "repos/$REPO/actions/runs?branch=$CURRENT_BRANCH&per_page=1" | jq -r '
    if (.workflow_runs | length) == 0 then
      "no-runs"
    else
      "\(.workflow_runs[0].status)-\(.workflow_runs[0].conclusion)"
    end
  ')

  case "$RUN_STATUS" in
    "completed-success")
      print_step "${PASS_ICON}" "CI checks passed."
      break
      ;;
    "completed-"*|"completed-failure"|"completed-cancelled"|"completed-skipped")
      abort_with_error "CI checks did not pass. Status: $RUN_STATUS. PR creation aborted."
      ;;
    "no-runs")
      abort_with_error "No GitHub Actions runs found on branch '$CURRENT_BRANCH'. Please push commits or check workflows."
      ;;
    *)
      print_step "${PROCESS_ICON}" "CI status is '$RUN_STATUS'. Waiting for completion... (retry $((retries+1))/${MAX_RETRIES})"
      ;;
  esac

  retries=$((retries+1))
  sleep $RETRY_DELAY
done

if [[ $retries -eq $MAX_RETRIES ]]; then
  abort_with_error "Timeout waiting for CI checks to complete."
fi

if [[ -z "$PR_NUMBER" ]]; then
  print_step "${PROCESS_ICON}" "Creating Pull Request..."
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

  print_step "${PASS_ICON}" "Pull Request created: ${PR_URL}"
else
  print_step "${PROCESS_ICON}" "Updating existing Pull Request #${PR_NUMBER}..."
  (gh pr edit "$PR_NUMBER" --title "$TITLE" --body "$BODY_CONTENT") &
  pid=$!; bar_animation $pid
  wait $pid || abort_with_error "Failed to update PR."

  print_step "${PASS_ICON}" "Pull Request updated: ${PR_URL}"
fi

# Add labels
IFS=',' read -ra ADD_LABELS <<< "$LABELS"
for lbl in "${ADD_LABELS[@]}"; do
  lbl_trimmed="$(echo "$lbl" | xargs)"
  if [[ -n "$lbl_trimmed" ]]; then
    print_step "${PROCESS_ICON}" "Adding label '${lbl_trimmed}' to PR..."
    gh pr edit "$PR_NUMBER" --add-label "$lbl_trimmed" >/dev/null || abort_with_error "Failed to add label '${lbl_trimmed}'."
  fi
done

# Assign milestone
if [[ -n "$MILESTONE" ]]; then
  print_step "${PROCESS_ICON}" "Assigning milestone '${MILESTONE}'..."
  gh pr edit "$PR_NUMBER" --milestone "$MILESTONE" >/dev/null || abort_with_error "Failed to assign milestone '${MILESTONE}'."
fi

# Assign assignees
IFS=',' read -ra ASSIGNEES_ARR <<< "$ASSIGNEES"
if [[ ${#ASSIGNEES_ARR[@]} -gt 0 && -n "${ASSIGNEES_ARR[0]}" ]]; then
  print_step "${PROCESS_ICON}" "Assigning to: ${ASSIGNEES}"
  gh pr edit "$PR_NUMBER" --add-assignee $ASSIGNEES >/dev/null || abort_with_error "Failed to assign PR."
fi

# Request reviewers
IFS=',' read -ra REVIEWERS_ARR <<< "$REVIEWERS"
if [[ ${#REVIEWERS_ARR[@]} -gt 0 && -n "${REVIEWERS_ARR[0]}" ]]; then
  print_step "${PROCESS_ICON}" "Requesting reviewer(s): ${REVIEWERS}"
  gh pr review-request add "$PR_NUMBER" --reviewer $REVIEWERS >/dev/null || abort_with_error "Failed to request reviewer(s)."
fi

# --- Final progress bar (full) ---
FULL_BAR_LENGTH=20
PROGRESS_FILL=$(printf '🟩%.0s' $(seq 1 $FULL_BAR_LENGTH))
PROGRESS_EMPTY=$(printf '⬜%.0s' $(seq 1 $((FULL_BAR_LENGTH - FULL_BAR_LENGTH))))
echo -e "\nProgress: [${PROGRESS_FILL}${PROGRESS_EMPTY}] 100% (Completed)"

# --- Final success message ---
print_step "${PASS_ICON}" "${GREEN}Feature PR process completed successfully! 🎉${NC}"
echo -e "\nLegend:"
echo -e "${INFO_ICON} Information"
echo -e "${PROCESS_ICON} In Progress"
echo -e "${PASS_ICON} Passed"
echo -e "${FAIL_ICON} Failed"
