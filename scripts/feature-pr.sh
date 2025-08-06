#!/bin/bash
set -euo pipefail

# === COLORS & ICONS ===
GREEN='\033[1;32m'
ORANGE='\033[38;5;214m'
RED='\033[1;31m'
WHITE='\033[1;37m'
BLUE='\033[1;34m'
BLACK='\033[1;30m'
NC='\033[0m'

ICON_PASS="${GREEN}✓${NC}"
ICON_WARN="${ORANGE}⚠${NC}"
ICON_FAIL="${RED}✗${NC}"
ICON_INFO="${BLUE}ℹ${NC}"
ICON_SKIP="${WHITE}○${NC}"

declare -A CHECKS_COUNT=( ["pass"]=0 ["warn"]=0 ["fail"]=0 ["info"]=0 ["skip"]=0 )
declare -a CHECK_RESULTS

# === HELPERS ===
# Replaced non-breaking spaces with standard spaces
log_info() { echo -e "${ICON_INFO} ${BLUE}$1${NC}"; CHECKS_COUNT[info]=$((CHECKS_COUNT[info]+1)); CHECK_RESULTS+=("info"); }
log_warn() { echo -e "${ICON_WARN} ${ORANGE}$1${NC}"; CHECKS_COUNT[warn]=$((CHECKS_COUNT[warn]+1)); CHECK_RESULTS+=("warn"); }
log_success() { echo -e "${ICON_PASS} ${GREEN}$1${NC}"; CHECKS_COUNT[pass]=$((CHECKS_COUNT[pass]+1)); CHECK_RESULTS+=("pass"); }
log_error() { echo -e "${ICON_FAIL} ${RED}$1${NC}"; CHECKS_COUNT[fail]=$((CHECKS_COUNT[fail]+1)); CHECK_RESULTS+=("fail"); exit 1; }
log_skip() { echo -e "${ICON_SKIP} ${WHITE}$1${NC}"; CHECKS_COUNT[skip]=$((CHECKS_COUNT[skip]+1)); CHECK_RESULTS+=("skip"); }

trim_list() { echo "$1" | sed 's/, */,/g'; }

# === PROGRESS BAR ===
print_progress_bar() {
  local total_checks=${#CHECK_RESULTS[@]}
  local filled_bar=""

  for result in "${CHECK_RESULTS[@]}"; do
    case "$result" in
      "pass") filled_bar+="🟩";;
      "warn") filled_bar+="🟧";;
      "fail") filled_bar+="🟥";;
      "info") filled_bar+="🟦";;
      "skip") filled_bar+="⬛";;
    esac
  done

  echo -e "\nProgress: [${filled_bar}] 100% (${total_checks}/$total_checks checks)"
}

# === REQUIRED TOOLS ===
for cmd in gh yq jq git; do
  command -v "$cmd" >/dev/null || log_error "Missing required tool: $cmd"
done

# === INIT ===
START_TIME=$(date +%s)
TARGET_BRANCH="dev"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
BRANCH_KEY="${CURRENT_BRANCH#feature/}"
METADATA_FILE=".github/features/${BRANCH_KEY}.md"

log_info "Current branch detected: ${CURRENT_BRANCH}"
log_info "Target branch for PR: ${TARGET_BRANCH}"

[[ -f "$METADATA_FILE" ]] || log_error "Metadata file not found: $METADATA_FILE"
log_success "Parsed metadata from ${METADATA_FILE}"

# === EXTRACT METADATA ===
extract_front_matter() {
  awk 'BEGIN{f=0} /^---$/{f++; next} f==1' "$1"
}
extract_body() {
  awk '/^---$/{f++} f==2' "$1"
}

FRONT=$(extract_front_matter "$METADATA_FILE")
BODY=$(extract_body "$METADATA_FILE")

TITLE=$(echo "$FRONT" | yq '.title // "Untitled PR"')
BODY_CONTENT="$BODY"
LINKED=$(echo "$FRONT" | yq '.linked_issue // ""')
ASSIGNEES=$(trim_list "$(echo "$FRONT" | yq '.assignees // ""')")
REVIEWERS=$(trim_list "$(echo "$FRONT" | yq '.reviewers // ""')")
LABELS=$(trim_list "$(echo "$FRONT" | yq '.labels // ""')")
MILESTONE=$(echo "$FRONT" | yq '.milestone // ""')

[[ -n "$LINKED" ]] && BODY_CONTENT="$BODY_CONTENT\n\nLinked issue: #$LINKED"

# === CHECK PR EXISTENCE ===
log_info "Checking for existing Pull Request..."
PR_DATA=$(gh pr list --head "$CURRENT_BRANCH" --base "$TARGET_BRANCH" --json number,state,url --limit 1)
PR_NUMBER=$(echo "$PR_DATA" | jq -r '.[0].number // empty')
PR_STATE=$(echo "$PR_DATA" | jq -r '.[0].state // empty')
PR_URL=$(echo "$PR_DATA" | jq -r '.[0].url // empty')

if [[ -n "$PR_NUMBER" ]]; then
  log_success "Found existing Pull Request #$PR_NUMBER ($PR_STATE)"
  log_info "$PR_URL"
  [[ "$PR_STATE" == "closed" ]] && gh pr reopen "$PR_NUMBER" && log_success "Reopened PR #$PR_NUMBER"
else
  log_info "No existing PR found"
fi

# === CHECK CI STATUS ===
log_info "Checking GitHub Actions status..."
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

MAX_RETRIES=5
for ((i=1; i<=MAX_RETRIES; i++)); do
  STATUS=$(gh api "repos/$REPO/actions/runs?branch=$CURRENT_BRANCH&per_page=1" |
    jq -r '.workflow_runs[0] | "\(.status)-\(.conclusion)"')

  if [[ "$STATUS" == "completed-success" ]]; then
    log_success "CI checks passed."
    break
  elif [[ "$i" -lt $MAX_RETRIES ]]; then
    log_info "CI status: $STATUS. Retrying ($i/$MAX_RETRIES)..."
    sleep 5
  else
    log_error "CI did not pass: $STATUS"
  fi
done

# === CREATE / UPDATE PR ===
if [[ -z "$PR_NUMBER" ]]; then
  log_info "Creating new PR..."
  PR_URL=$(gh pr create --title "$TITLE" --body "$BODY_CONTENT" --base "$TARGET_BRANCH" --head "$CURRENT_BRANCH")
  log_success "Created PR: $PR_URL"
else
  log_info "Updating PR #$PR_NUMBER..."
  gh pr edit "$PR_NUMBER" --title "$TITLE" --body "$BODY_CONTENT"
  log_success "Updated PR: $PR_URL"
fi

# === LABELS ===
if [[ -n "$LABELS" ]]; then
  for label in $(echo "$LABELS" | tr ',' ' '); do
    log_info "Adding label '$label'"
    gh pr edit "$PR_NUMBER" --add-label "$label" >/dev/null
  done
fi

# === MILESTONE ===
[[ -n "$MILESTONE" ]] && log_info "Assigning milestone '$MILESTONE'" && gh pr edit "$PR_NUMBER" --milestone "$MILESTONE"

# === ASSIGNEES ===
[[ -n "$ASSIGNEES" ]] && log_info "Assigning to: $ASSIGNEES" && gh pr edit "$PR_NUMBER" --add-assignee "$ASSIGNEES"

# === REVIEWERS ===
if [[ -n "$REVIEWERS" ]]; then
  log_info "Requesting reviewer(s): $REVIEWERS"
  EXISTING_REVIEWERS=$(gh pr view "$PR_NUMBER" --json reviewRequests -q '.reviewRequests[].login')

  for reviewer in $(echo "$REVIEWERS" | tr ',' ' '); do
    if echo "$EXISTING_REVIEWERS" | grep -q "^$reviewer$"; then
      log_skip "Reviewer '$reviewer' already assigned."
    else
      if gh pr edit "$PR_NUMBER" --add-reviewer "$reviewer"; then
        log_success "Reviewer '$reviewer' requested."
      else
        log_warn "Failed to assign reviewer '$reviewer'."
      fi
    fi
  done
fi

# === SUMMARY ===
print_progress_bar

echo -e "\n📊 Validation Summary:"
printf "  ${ICON_PASS} Passed    🟢  ⇒ %2d\n" "${CHECKS_COUNT[pass]}"
printf "  ${ICON_WARN} Warnings  🟠  ⇒ %2d\n" "${CHECKS_COUNT[warn]}"
printf "  ${ICON_FAIL} Failures  🔴  ⇒ %2d\n" "${CHECKS_COUNT[fail]}"
printf "  ${ICON_INFO} Info      🔵  ⇒ %2d\n" "${CHECKS_COUNT[info]}"
printf "  ${ICON_SKIP} Skipped   ⚫  ⇒ %2d\n" "${CHECKS_COUNT[skip]}"

END_TIME=$(date +%s)
echo -e "\n⏱ Completed in $((END_TIME - START_TIME)) seconds\n"
log_success "🎉 Feature Pull Request completed successfully! View it at: $PR_URL"
