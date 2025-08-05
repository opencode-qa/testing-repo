#!/bin/bash
set -euo pipefail

# === COLORS & ICONS ===
# Theme colors
GREEN='\033[1;32m'
ORANGE='\033[38;5;214m'
RED='\033[1;31m'
WHITE='\033[1;37m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'
BOLD='\033[1m'

# Theme icons
PASS_ICON="${GREEN}✓${NC}"
WARN_ICON="${ORANGE}⚠${NC}"
FAIL_ICON="${RED}✗${NC}"
SKIP_ICON="${WHITE}➤${NC}"
OPTIONAL_ICON="${CYAN}◇${NC}"

# Custom icons for this script
ICON_SUCCESS="${PASS_ICON}"
ICON_ON_TRACK="${WHITE}⚪${NC}"
ICON_OVERDUE="${RED}✗${NC}"
ICON_PROCESSING="${ORANGE}🟡${NC}"
ICON_NEXT_UPCOMING="${ORANGE}🟠${NC}"

# Bigger icons for summary
GREEN_CIRCLE="${GREEN}🟢${NC}"
WHITE_CIRCLE="${WHITE}⚪${NC}"
RED_CIRCLE="${RED}🔴${NC}"
WARNING_ICON="${ORANGE}⚠️${NC}"


# === CONFIGURATION ===
TARGET_BRANCH="dev"
DEFAULT_METADATA_DIR=".github/issues/features"

# === HELPERS ===
print_step() {
  local icon=$1 message=$2
  echo -e "$icon ${WHITE}${message}${NC}"
}
abort_with_error() {
  echo -e "${RED}${FAIL_ICON} ${1}${NC}"; exit 1;
}

# === DEPENDENCIES ===
command -v gh >/dev/null || abort_with_error "GitHub CLI (gh) not installed."
command -v yq >/dev/null || abort_with_error "YAML parser (yq) not installed."
command -v jq >/dev/null || abort_with_error "jq (JSON parser) not installed."

# === INPUT PARSING ===
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
    *) echo "Unknown argument: $1" && exit 1 ;;
  esac
  shift
done

# === BRANCH DETECTION ===
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
print_step "$ICON_PROCESSING" "Current branch detected: ${CURRENT_BRANCH}"
print_step "$ICON_PROCESSING" "Target branch for PR: ${TARGET_BRANCH}"

# === METADATA ===
BRANCH_KEY="${CURRENT_BRANCH#feature/}"
METADATA_FILE="${DEFAULT_METADATA_DIR}/${BRANCH_KEY}.md"

[[ -f "$METADATA_FILE" ]] || abort_with_error "Metadata file '${METADATA_FILE}' not found."

# === EXTRACT FIELDS WITH YQ ===
ASSIGNEES=$(yq '.assignees | join(",")' "$METADATA_FILE" 2>/dev/null || echo "")
REVIEWERS=$(yq '.reviewers | join(",")' "$METADATA_FILE" 2>/dev/null || echo "")
LINKED_ISSUE=$(yq '.linked_issue' "$METADATA_FILE" 2>/dev/null || echo "")
MILESTONE=$(yq '.milestone' "$METADATA_FILE" 2>/dev/null || echo "")
LABELS=$(yq '.labels | join(",")' "$METADATA_FILE" 2>/dev/null || echo "")

print_step "$PASS_ICON" "Parsed metadata from ${METADATA_FILE}"

# === TITLE/BODY HANDLING ===
[[ -z "$TITLE" ]] && TITLE=$(yq '.title' "$METADATA_FILE" || echo "Untitled PR")

# === Extract PR body (excluding front matter)
extract_body_content() {
  awk '/^---$/ {count++; next} count >= 2 {print}' "$1"
}
BODY_CONTENT=$(extract_body_content "$METADATA_FILE")

# === DRY RUN ===
if $DRY_RUN; then
  echo -e "\n${YELLOW}--- Dry Run Mode ---${NC}"
  echo "Title       : $TITLE"
  echo "Assignees   : $ASSIGNEES"
  echo "Reviewers   : $REVIEWERS"
  echo "Milestone   : $MILESTONE"
  echo "Labels      : $LABELS"
  echo "Issue       : #$LINKED_ISSUE"
  echo "Body:"
  echo "$BODY_CONTENT"
  exit 0
fi

# === CHECK GITHUB ACTIONS (CI STATUS)
print_step "$ICON_PROCESSING" "Checking GitHub Actions for branch '$CURRENT_BRANCH'..."
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
RUN_STATUS=$(gh api "repos/$REPO/actions/runs?branch=$CURRENT_BRANCH&per_page=1" \
  | jq -r '.workflow_runs[0] | "\(.status)-\(.conclusion)"')

if [[ "$RUN_STATUS" != "completed-success" ]]; then
  abort_with_error "CI checks not passed for branch '$CURRENT_BRANCH'. Status: $RUN_STATUS. PR creation aborted."
fi

print_step "$PASS_ICON" "All CI checks passed."

# === CREATE PR ===
print_step "$ICON_PROCESSING" "Creating Pull Request from '${CURRENT_BRANCH}' to '${TARGET_BRANCH}'..."

PR_CREATE_OUTPUT=$(gh pr create \
  --title "$TITLE" \
  --body "$BODY_CONTENT" \
  --base "$TARGET_BRANCH" \
  --head "$CURRENT_BRANCH" \
  ${LINKED_ISSUE:+--linked-issue "$LINKED_ISSUE"} 2>&1) || {
    echo -e "${RED}${FAIL_ICON} Failed to create PR. GH CLI output:${NC}"
    echo "$PR_CREATE_OUTPUT"
    exit 1
}

PR_NUMBER=$(echo "$PR_CREATE_OUTPUT" | grep -Eo 'https://github.com/.*/pull/[0-9]+' | grep -Eo '[0-9]+$')
PR_URL="https://github.com/$REPO/pull/$PR_NUMBER"
print_step "$PASS_ICON" "Pull Request created: ${PR_URL}"

# === CREATE & ADD LABELS ===
if [[ -n "$LABELS" ]]; then
  for label in $(echo "$LABELS" | tr ',' '\n'); do
    if ! gh label list | awk '{print $1}' | grep -qx "$label"; then
      print_step "$ICON_PROCESSING" "Label '${label}' not found. Creating..."
      gh label create "$label" --color "ededed" --description "Auto-created label" >/dev/null 2>&1 || \
        print_step "$FAIL_ICON" "Failed to create label '${label}'"
    fi

    print_step "$ICON_PROCESSING" "Adding label '${label}' to PR..."
    gh pr edit "$PR_NUMBER" --add-label "$label" >/dev/null 2>&1 || \
      print_step "$FAIL_ICON" "Failed to add label '${label}'"
  done
fi

# === ASSIGN USERS ===
[[ -n "$ASSIGNEES" ]] && gh pr edit "$PR_NUMBER" --add-assignee "$ASSIGNEES" >/dev/null && \
  print_step "$PASS_ICON" "Assigned to: $ASSIGNEES"

[[ -n "$REVIEWERS" ]] && gh pr edit "$PR_NUMBER" --add-reviewer "$REVIEWERS" >/dev/null && \
  print_step "$PASS_ICON" "Requested reviewers: $REVIEWERS"

# === MILESTONE HANDLING ===
if [[ -n "$MILESTONE" ]]; then
  MILESTONE_ID=$(gh api "repos/$REPO/milestones" | jq ".[] | select(.title == \"$MILESTONE\") | .number")
  if [[ -n "$MILESTONE_ID" ]]; then
    gh api -X PATCH "repos/$REPO/issues/$PR_NUMBER" -f milestone="$MILESTONE_ID" >/dev/null && \
      print_step "$PASS_ICON" "Assigned milestone: $MILESTONE"
  else
    print_step "$FAIL_ICON" "Milestone '$MILESTONE' not found or assignable."
  fi
fi

echo -e "${PASS_ICON} All done!${NC}"
