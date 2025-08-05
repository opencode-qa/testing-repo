#!/bin/bash
# Refactored GitHub Issue Creation Script
set -euo pipefail

# === CONFIGURATION ===
ASSIGNEE="${1:-$(gh api user --jq '.login')}"
LABEL_FILTER="${2:-}"
ISSUES_DIR=".github/issues"

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


# === FUNCTIONS ===

# Function to print a status line with a colored icon and message
print_status_line() {
  local title=$1 icon=$2 status_text=$3
  echo -e "  $icon ${WHITE}→ $title ⇒ $status_text${NC}"
}

normalize_title() {
  echo "$1" | perl -CSDA -pe 's/\p{So}//g' | sed 's/[^[:alnum:]]//g' | tr '[:upper:]' '[:lower:]'
}

declare -A known_labels=()
declare -a existing_labels_lower=()

cache_existing_labels() {
  mapfile -t existing_labels_lower < <(gh label list --limit 1000 | awk '{print tolower($1)}')
}

create_label_if_needed() {
  local label_name="$1"
  label_name=$(echo "$label_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"')

  if [[ -n "${known_labels[$label_name]:-}" ]]; then return 0; fi

  local lower_label=$(echo "$label_name" | tr '[:upper:]' '[:lower:]')
  if printf "%s\n" "${existing_labels_lower[@]}" | grep -qx "$lower_label"; then
    known_labels[$label_name]=1
    return 0
  fi

  if gh label create "$label_name" --color "$(echo "$label_name" | sha256sum | head -c 6)" &>/dev/null; then
    known_labels[$label_name]=1
    existing_labels_lower+=("$lower_label")
    return 0
  fi

  return 1
}

create_issue_from_file() {
  local file="$1"
  local raw_title=$(awk -F': ' '/^title:/ {print $2; exit}' "$file")
  local clean_title=$(echo "$raw_title" | sed 's/^"//;s/"$//' | xargs)
  local compare_title=$(normalize_title "$clean_title")

  local existing_titles
  mapfile -t existing_titles < <(gh issue list --limit 1000 --json title --jq '.[].title')

  for title in "${existing_titles[@]}"; do
    if [[ "$(normalize_title "$title")" == "$compare_title" ]]; then
      print_status_line "$clean_title" "$ICON_ON_TRACK" "Already exists"
      return 1
    fi
  done

  local labels=$(awk -F': ' '/^labels:/ {print $2; exit}' "$file" | tr -d '[]"' | tr ',' '\n' | xargs -n1)

  # Check label filter match
  if [[ -n "$LABEL_FILTER" ]]; then
    local found_match=0
    for label in $labels; do
      if [[ "${label,,}" == "${LABEL_FILTER,,}" ]]; then
        found_match=1
        break
      fi
    done
    if [[ $found_match -eq 0 ]]; then
      return 1
    fi
  fi

  local milestone=$(awk -F': ' '/^milestone:/ {print $2; exit}' "$file" | tr -d '"')
  local milestone_arg=()
  if [[ -n "$milestone" ]]; then
    milestone_arg=("--milestone" "$milestone")
  fi

  local body=$(awk '/^---$/ {count++; next} count >= 2 {print}' "$file")

  local label_args=()
  for label in $labels; do
    if create_label_if_needed "$label"; then
      label_args+=("-l" "$label")
    fi
  done

  if issue_url=$(gh issue create -t "$clean_title" -b "$body" --assignee "$ASSIGNEE" "${label_args[@]}" "${milestone_arg[@]}" 2>/dev/null); then
    print_status_line "$clean_title" "$ICON_SUCCESS" "Created"
    return 0
  else
    print_status_line "$clean_title" "$FAIL_ICON" "Failed"
    return 2
  fi
}

main() {
  if [[ ! -d "$ISSUES_DIR" ]]; then
    echo -e "${RED}❌ Directory '$ISSUES_DIR' not found.${NC}"
    exit 1
  fi

  cache_existing_labels

  echo -e "\n${CYAN}🚀 Starting issue creation from '$ISSUES_DIR'...${NC}"
  local created=0 skipped=0 failed=0 total=0
  local current_count=0

  local file_list=("$ISSUES_DIR"/*.md)
  for file in "${file_list[@]}"; do
    [[ -f "$file" ]] || continue
    total=$((total + 1))
  done

  for file in "${file_list[@]}"; do
    [[ -f "$file" ]] || continue
    current_count=$((current_count + 1))
    if create_issue_from_file "$file"; then
      created=$((created + 1))
    else
      status=$?
      if [[ $status -eq 1 ]]; then
        skipped=$((skipped + 1))
      else
        failed=$((failed + 1))
      fi
    fi
  done

  echo -e "\n${BOLD}${PURPLE}📊 Issue Creation Summary:${NC}"
  echo -e "  ${PASS_ICON} Created → ${GREEN_CIRCLE} ⇒ $created"
  echo -e "  ${SKIP_ICON} Skipped → ${WHITE_CIRCLE} ⇒ $skipped"
  echo -e "  ${FAIL_ICON} Failed  → ${RED_CIRCLE} ⇒ $failed"
}

main "$@"
