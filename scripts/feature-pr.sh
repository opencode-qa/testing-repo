#!/bin/bash
set -euo pipefail

# === COLORS & ICONS ===
GREEN='\033[1;32m'
ORANGE='\033[38;5;214m'
RED='\033[1;31m'
WHITE='\033[1;37m'
BLUE='\033[1;34m'
NC='\033[0m'

ICON_PASS="${GREEN}✓${NC}"
ICON_FAIL="${RED}✗${NC}"
ICON_WARN="${ORANGE}🟡${NC}"
ICON_INFO="${BLUE}🔵${NC}"
ICON_SKIP="${WHITE}○${NC}"

# === PROGRESS BAR ===
print_progress_bar() {
  local total=20
  local filled=$1
  local percent=$(( (filled * 100) / total ))
  local bar=""
  for ((i=1; i<=total; i++)); do
    if (( i <= filled )); then
      bar+="🟩"
    else
      bar+="⬜"
    fi
  done
  echo -e "Progress: [${bar}] ${percent}%"
}

# === LOGGING HELPERS ===
log_info()    { echo -e "${ICON_INFO} ${BLUE}$1${NC}"; }
log_warn()    { echo -e "${ICON_WARN} ${ORANGE}$1${NC}"; }
log_success() { echo -e "${ICON_PASS} ${GREEN}$1${NC}"; }
log_error()   { echo -e "${ICON_FAIL} ${RED}$1${NC}"; exit 1; }
log_skip()    { echo -e "${ICON_SKIP} ${WHITE}$1${NC}"; }

# === BAR ANIMATION ===
bar_animation() {
  local pid=$1
  local spinstr='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    for i in $(seq 0 3); do
      printf "\r${ORANGE}[%c]${NC} " "${spinstr:i:1}"
      sleep 0.1
    done
  done
  printf "\r"
}

# === PARSE HELPERS ===
parse_list_or_string() {
  local input="$1"
  echo "$input" | yq 'if type == "!!seq" then join(",") else . end' 2>/dev/null || echo "$input"
}

trim_commas_spaces() {
  echo "$1" | sed 's/, */,/g'
}

# === CHECK REQUIRED TOOLS ===
for cmd in gh yq jq git; do
  command -v "$cmd" >/dev/null || log_error "Required command '$cmd' not installed."
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
    *) log_error "Unknown argument: $1" ;;
  esac
  shift
done

TARGET_BRANCH="dev"
DEFAULT_METADATA_DIR=".github/features"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

log_info "Current branch detected: ${CURRENT_BRANCH}"
log_warn "Target branch for PR: ${TARGET_BRANCH}"

BRANCH_KEY="${CURRENT_BRANCH#feature/}"
METADATA_FILE="${DEFAULT_METADATA_DIR}/${BRANCH_KEY}.md"

[[ -f "$METADATA_FILE" ]] || log_error "Metadata file ${METADATA_FILE} not found!"

log_success "Parsed metadata from ${METADATA_FILE}"

extract_front_matter() {
  awk 'BEGIN {found=0} /^---$/ {found+=1; next} found==1 {print}' "$1"
}
FRONT_MATTER=$(extract_front_matter "$METADATA_FILE")

ASSIGNEES=$(parse_list_or_string "$(echo "$FRONT_MATTER" | yq '.assignees // ""')")
REVIEWERS=$(parse_list_or_string "$(echo "$FRONT_MATTER" | yq '.reviewers // ""')")
LABELS=$(parse_list_or_string "$(echo "$FRONT_MATTER" | yq '.labels // ""')")
LINKED_ISSUE=$(echo "$FRONT_MATTER" | yq '.linked_issue // ""')
MILESTONE=$(echo "$FRONT_MATTER" | yq '.milestone // ""')
RAW_TITLE=$(echo "$FRONT_MATTER" | yq '.title // ""')

ASSIGNEES=$(trim_commas_spaces "$ASSIGNEES")
REVIEWERS=$(trim_commas_spaces "$REVIEWERS")
LABELS=$(trim_commas_spaces "$LABELS")

[[ -z "$TITLE" ]] && TITLE="$RAW_TITLE"
[[ -z "$TITLE" ]] && TITLE="Untitled PR"

extract_body_content() {
  awk '/^---$/ {count++; next} count >= 2 {print}' "$1"
}
BODY_CONTENT=$(extract_body_content "$METADATA_FILE")

[[ -n "$BODY" ]] && BODY_CONTENT="$BODY"
[[ -n "$LINKED_ISSUE" ]] && BODY_CONTENT="$BODY_CONTENT\n\nLinked issue: #$LINKED_ISSUE"

if $DRY_RUN; then
  log_info "--- Dry Run Mode ---"
  echo -e "${BLUE}Title       : $TITLE${NC}"
  echo -e "${BLUE}Assignees   : $ASSIGNEES${NC}"
  echo -e "${BLUE}Reviewers   : $REVIEWERS${NC}"
  echo -e "${BLUE}Milestone   : $MILESTONE${NC}"
  echo -e "${BLUE}Labels      : $LABELS${NC}"
  echo -e "${BLUE}Linked issue: #$LINKED_ISSUE${NC}"
  echo -e "\n${WHITE}Body:${NC}\n$BODY_CONTENT"
  exit 0
fi

log_warn "Checking for existing Pull Request..."
EXISTING_PR_JSON=$(gh pr list --head "$CURRENT_BRANCH" --base "$TARGET_BRANCH" --json number,state,url --limit 1)
PR_NUMBER=$(echo "$EXISTING_PR_JSON" | jq -r '.[0].number // empty')
PR_STATE=$(echo "$EXISTING_PR_JSON" | jq -r '.[0].state // empty')
PR_URL=$(echo "$EXISTING_PR_JSON" | jq -r '.[0].url // empty')

if [[ -n "$PR_NUMBER" ]]; then
  log_warn "Found existing Pull Request #$PR_NUMBER ($PR_STATE)."
  log_warn "You can view it here: $PR_URL"
  if [[ "$PR_STATE" == "closed" ]]; then
    log_warn "Reopening closed PR #$PR_NUMBER..."
    gh pr reopen "$PR_NUMBER" || log_error "Failed to reopen PR."
  fi
else
  log_info "No existing PR found. Will create a new one."
fi

# === CHECK CI STATUS WITH RETRY LOOP ===
log_warn "Checking GitHub Actions status for branch '$CURRENT_BRANCH'..."
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

MAX_RETRIES=5
RETRY_INTERVAL=10
for ((i=1; i<=MAX_RETRIES; i++)); do
  RUN_STATUS=$(gh api "repos/$REPO/actions/runs?branch=$CURRENT_BRANCH&per_page=1" |
    jq -r 'if (.workflow_runs | length) == 0 then "no-runs" else "\(.workflow_runs[0].status)-\(.workflow_runs[0].conclusion)" end')

  if [[ "$RUN_STATUS" == "completed-success" ]]; then
    log_success "CI checks passed."
    break
  elif [[ "$RUN_STATUS" == "no-runs" ]]; then
    log_error "No CI runs found for this branch."
  elif [[ "$i" -lt "$MAX_RETRIES" ]]; then
    log_warn "CI in progress (status: $RUN_STATUS). Retrying in $RETRY_INTERVAL seconds... ($i/$MAX_RETRIES)"
    sleep "$RETRY_INTERVAL"
  else
    log_error "CI checks did not pass after retries. Status: $RUN_STATUS"
  fi
done

# === CREATE OR UPDATE PR ===
if [[ -z "$PR_NUMBER" ]]; then
  log_warn "Creating new Pull Request..."
  PR_URL=$(gh pr create \
    --title "$TITLE" \
    --body "$BODY_CONTENT" \
    --base "$TARGET_BRANCH" \
    --head "$CURRENT_BRANCH")
  log_success "Pull Request created: $PR_URL"
else
  log_warn "Updating existing Pull Request #$PR_NUMBER..."
  gh pr edit "$PR_NUMBER" --title "$TITLE" --body "$BODY_CONTENT"
  log_success "Pull Request updated: $PR_URL"
fi

# === APPLY LABELS ===
if [[ -n "$LABELS" ]]; then
  IFS=',' read -ra LABEL_ARRAY <<< "$LABELS"
  for label in "${LABEL_ARRAY[@]}"; do
    label=$(echo "$label" | xargs)
    log_warn "Adding label '$label' to PR..."
    gh pr edit "$PR_NUMBER" --add-label "$label" >/dev/null
  done
fi

# === MILESTONE ===
if [[ -n "$MILESTONE" ]]; then
  log_warn "Assigning milestone '$MILESTONE'..."
  gh pr edit "$PR_NUMBER" --milestone "$MILESTONE" >/dev/null
fi

# === ASSIGNEES ===
if [[ -n "$ASSIGNEES" ]]; then
  log_warn "Assigning to: $ASSIGNEES..."
  gh pr edit "$PR_NUMBER" --add-assignee "$ASSIGNEES" >/dev/null
fi

# === REVIEWERS ===
if [[ -n "$REVIEWERS" ]]; then
  log_warn "Requesting reviewer(s): $REVIEWERS..."

  # Fetch existing reviewers
  EXISTING_REVIEWERS=$(gh pr view "$PR_NUMBER" --json reviewRequests -q '.reviewRequests[].login')

  for reviewer in $(echo "$REVIEWERS" | tr ',' ' '); do
    if echo "$EXISTING_REVIEWERS" | grep -q "^$reviewer$"; then
      log_skip "Reviewer '$reviewer' is already assigned. Skipping..."
    else
      if gh pr review --request "$reviewer" 2>/dev/null; then
        log_success "Requested reviewer: $reviewer"
      else
        log_warn "Could not request reviewer '$reviewer' (may already be assigned or invalid)."
      fi
    fi
  done
fi

# === FINAL SUCCESS ===
print_progress_bar 20
log_success "🎉 Feature Pull Request completed successfully! You can view it here: $PR_URL"

# === LEGEND ===
echo -e "\nLegend:"
echo -e "${ICON_INFO} ${BLUE}Information${NC}"
echo -e "${ICON_WARN} ${ORANGE}In Progress${NC}"
echo -e "${ICON_PASS} ${GREEN}Passed${NC}"
echo -e "${ICON_FAIL} ${RED}Failed${NC}"
echo -e "${ICON_SKIP} ${WHITE}Skipped${NC}"
