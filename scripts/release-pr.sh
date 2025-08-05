#!/usr/bin/env bash
set -euo pipefail

# === COLOR THEME & ICONS ===
GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'
WHITE='\033[1;37m'; BLUE='\033[1;34m'; PURPLE='\033[1;35m'
CYAN='\033[1;36m'; ORANGE='\033[38;5;214m'; NC='\033[0m'

PASS_ICON="${GREEN}✓${NC}"
WARN_ICON="${ORANGE}⚠${NC}"
FAIL_ICON="${RED}✗${NC}"
SKIP_ICON="${WHITE}➤${NC}"
OPTIONAL_ICON="${CYAN}◇${NC}"

ICON_SUCCESS="🟢"
ICON_PROCESSING="⚪"
ICON_FAILURE="🔴"

print_step() { echo -e "${1} ${2}"; }
abort_with_error() { echo -e "${RED}${ICON_FAILURE} $1${NC}"; exit 1; }

show_progress_bar() {
  local current=$1 total=$2
  local percent=$((100 * current / total))
  local bar=""

  for ((i = 0; i < total; i++)); do
    if (( i < current )); then bar+="🟩"
    else bar+="⬛"
    fi
  done

  echo -e "\n${BLUE}Progress Summary:${NC}"
  echo -e "[${bar}] ${percent}% ($current/$total tasks completed)"
}

# === CONFIGURATION ===
TARGET_BRANCH="main"
DEFAULT_METADATA_DIR=".github/releases"
TITLE=""; BODY=""; DRY_RUN=false; METADATA_FILE=""
declare -a COMPLETED_TASKS

# === DEPENDENCY CHECK ===
check_dependencies() {
  for cmd in gh yq jq; do
    if ! command -v "$cmd" &>/dev/null; then
      abort_with_error "Required command '$cmd' not installed."
    fi
    COMPLETED_TASKS+=("dep-$cmd")
  done
}

# === ARGUMENT PARSING ===
parse_arguments() {
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
}

# === MAIN ===
main() {
  echo -e "${PURPLE}🚀 release-pr.sh — Create a GitHub Release Pull Request${NC}"
  echo ""

  check_dependencies
  parse_arguments "$@"

  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  print_step "$ICON_PROCESSING" "Current branch: $CURRENT_BRANCH"
  print_step "$ICON_PROCESSING" "Target branch: $TARGET_BRANCH"
  COMPLETED_TASKS+=("branch-checked")

  # Determine metadata
  if [[ -z "$METADATA_FILE" ]]; then
    BRANCH_KEY="${CURRENT_BRANCH#*/}"
    METADATA_FILE="${DEFAULT_METADATA_DIR}/${BRANCH_KEY}.md"
  fi
  [[ -f "$METADATA_FILE" ]] || abort_with_error "Metadata file '$METADATA_FILE' not found."
  COMPLETED_TASKS+=("metadata-located")

  # Parse YAML front matter
  YAML_FRONT_MATTER=$(awk 'BEGIN{in_yaml=0} /^---$/ {in_yaml+=1; next} in_yaml==1 {print}' "$METADATA_FILE")
  ASSIGNEES=$(echo "$YAML_FRONT_MATTER" | yq '.assignees // [] | join(",")')
  REVIEWERS=$(echo "$YAML_FRONT_MATTER" | yq '.reviewers // [] | join(",")')
  MILESTONE=$(echo "$YAML_FRONT_MATTER" | yq '.milestone // ""')
  LABELS=$(echo "$YAML_FRONT_MATTER" | yq '.labels // [] | join(",")')
  [[ -z "$TITLE" ]] && TITLE=$(echo "$YAML_FRONT_MATTER" | yq '.title // "Release PR"')

  if [[ -z "$BODY" ]]; then
    BODY_CONTENT=$(awk '/^---$/ {count++} count==2 {next; in_body=1} in_body {print}' "$METADATA_FILE")
  else
    BODY_CONTENT="$BODY"
  fi
  COMPLETED_TASKS+=("metadata-parsed")

  # === Dry Run ===
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

  # Check CI
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  print_step "$ICON_PROCESSING" "Checking CI status on '$CURRENT_BRANCH'..."
  RUN_STATUS=$(gh api "repos/$REPO/actions/runs?branch=$CURRENT_BRANCH&per_page=1" | jq -r '
    if (.workflow_runs | length)==0 then "no-runs"
    else "\(.workflow_runs[0].status)-\(.workflow_runs[0].conclusion)" end
  ')

  if [[ "$RUN_STATUS" == "no-runs" ]]; then
    abort_with_error "No GitHub Actions runs found on '$CURRENT_BRANCH'."
  elif [[ "$RUN_STATUS" != "completed-success" ]]; then
    abort_with_error "CI not passed (status=$RUN_STATUS)."
  fi
  print_step "$ICON_SUCCESS" "CI passed."
  COMPLETED_TASKS+=("ci-ok")

  # Create PR
  print_step "$ICON_PROCESSING" "Creating pull request..."
  PR_OUT=$(gh pr create --title "$TITLE" --body "$BODY_CONTENT" --base "$TARGET_BRANCH" --head "$CURRENT_BRANCH" 2>&1) \
    || abort_with_error "Failed to create PR: $PR_OUT"

  PR_NUMBER=$(echo "$PR_OUT" | grep -Eo 'pull/[0-9]+' | grep -Eo '[0-9]+')
  PR_URL="https://github.com/$REPO/pull/$PR_NUMBER"
  print_step "$ICON_SUCCESS" "PR created: $PR_URL"
  COMPLETED_TASKS+=("pr-created")

  # Add Labels
  LABELS="$LABELS,${CURRENT_BRANCH##*/}"
  for lbl in $(echo "$LABELS" | tr ',' '\n' | sed '/^$/d'); do
    if ! gh label list | awk '{print $1}' | grep -qx "$lbl"; then
      gh label create "$lbl" --color ededee --description "Auto label" >/dev/null
    fi
    gh pr edit "$PR_NUMBER" --add-label "$lbl" >/dev/null
  done
  COMPLETED_TASKS+=("labels-added")

  # Assign assignees/reviewers
  [[ -n "$ASSIGNEES" ]] && gh pr edit "$PR_NUMBER" --add-assignee "$ASSIGNEES" >/dev/null && print_step "$ICON_SUCCESS" "Assigned: $ASSIGNEES"
  [[ -n "$REVIEWERS" ]] && gh pr edit "$PR_NUMBER" --add-reviewer "$REVIEWERS" >/dev/null && print_step "$ICON_SUCCESS" "Reviewers: $REVIEWERS"
  COMPLETED_TASKS+=("assignments-done")

  # Set milestone
  if [[ -n "$MILESTONE" ]]; then
    MID=$(gh api "repos/$REPO/milestones" | jq ".[] | select(.title==\"$MILESTONE\").number")
    if [[ -n "$MID" ]]; then
      gh api -X PATCH "repos/$REPO/issues/$PR_NUMBER" -f milestone="$MID" >/dev/null
      print_step "$ICON_SUCCESS" "Milestone set: $MILESTONE"
    else
      print_step "$WARN_ICON" "Milestone '$MILESTONE' not found."
    fi
  fi
  COMPLETED_TASKS+=("milestone-set")

  # === Final Output ===
  show_progress_bar ${#COMPLETED_TASKS[@]} 8
  echo -e "\n${GREEN}✓ release-pr.sh completed successfully!${NC}"
}

main "$@"
