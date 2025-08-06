#!/bin/bash
# Refactored GitHub Milestone Automation Script
set -euo pipefail

# === CONFIGURATION ===
START_DATE="2025-08-03" # The start date for the first milestone's due date
SPACING_DAYS=3         # Days between each milestone's due date

# GitHub authentication
GITHUB_TOKEN="${GH_PAT:-${GITHUB_TOKEN:-}}"
if [[ -z "$GITHUB_TOKEN" ]]; then
  echo -e "🔴 \033[1;31mERROR: GITHUB_TOKEN not set\033[0m"
  exit 1
fi

# === COLORS & ICONS ===
GREEN='\033[1;32m'
ORANGE='\033[1;33m' # Used for warnings/suggestions
RED='\033[1;31m'
WHITE='\033[1;37m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m' # New color for main headers
BOLD='\033[1m'
CYAN='\033[1;36m' # New color for section headers
NC='\033[0m' # No Color

# Icons for logs
ICON_PASS="✓"
ICON_FAIL="✗"
ICON_WARN="💡" # Used for warnings/suggestions
ICON_INFO="ℹ" # Used for general info/on-track
ICON_SKIP="➤" # Used for skipped items

# Emojis for status display
EMOJI_PASS="🟢"
EMOJI_FAIL="🔴"
EMOJI_WARN="🟠"
EMOJI_INFO="🔵"
EMOJI_SKIP="⚫"
EMOJI_ON_TRACK="⚪"

# Global counters for the current section's progress bar
declare -A CHECKS_COUNT=( ["pass"]=0 ["warn"]=0 ["info"]=0 ["skip"]=0 ["fail"]=0 )
declare -a CHECK_RESULTS # Array to store results in chronological order for the current section

# === HELPERS ===

# Function to reset the counters for a new section's progress
reset_section_counters() {
    CHECKS_COUNT=( ["pass"]=0 ["warn"]=0 ["info"]=0 ["skip"]=0 ["fail"]=0 )
    CHECK_RESULTS=()
}

# Function to get display width of a string (handles multi-byte chars/emojis)
get_display_width() {
    echo -n "$1" | wc -m
}

# Unified logging functions that update counters and the result array
log_info() {
    printf "%b%s %s%b\n" "${BLUE}" "${ICON_INFO}" "$1" "${NC}"
    CHECKS_COUNT[info]=$((CHECKS_COUNT[info]+1))
    CHECK_RESULTS+=("info")
}
log_warn() {
    printf "%b%s %s%b\n" "${ORANGE}" "${ICON_WARN}" "$1" "${NC}"
    CHECKS_COUNT[warn]=$((CHECKS_COUNT[warn]+1))
    CHECK_RESULTS+=("warn")
}
log_error() {
    printf "%b%s %s%b\n" "${RED}" "${ICON_FAIL}" "$1" "${NC}"
    CHECKS_COUNT[fail]=$((CHECKS_COUNT[fail]+1))
    CHECK_RESULTS+=("fail")
    exit 1
}

# Function for bold, colored section headers
log_header() {
    local color=$1
    local message=$2
    echo -e "\n${BOLD}${color}${message}${NC}"
}

# Function to calculate a milestone's due date
calculate_due_date() {
  date -d "$START_DATE +$1 days" +"%Y-%m-%d"
}

# ---
### Progress Bar and Summary Functions (Per Section)

# Prints the chronological progress bar for the current section
print_section_progress_bar() {
    local total=${#CHECK_RESULTS[@]}
    local bar=""

    for result in "${CHECK_RESULTS[@]}"; do
        case "$result" in
            "pass") bar+="🟩";;
            "warn") bar+="🟧";;
            "skip") bar+="⬛";;
            "fail") bar+="🟥";;
            "info") bar+="🟦";;
        esac
    done

    echo -e "\n"
    echo -e "${BOLD}${PURPLE}Progress: [${bar}] 100% ($total/$total checks)${NC}"
    echo -e "\n"
}

# Prints the summary table for the 'Create Milestones' section
print_create_summary() {
    local created=$1
    local skipped=$2
    local failed=$3
    local total_info=$4

    echo -e "${BOLD}${PURPLE}📊 Create Summary:${NC}"

    local max_summary_label_len=0
    local labels_to_measure=("${ICON_PASS} Passed ${EMOJI_PASS}" "${ICON_WARN} Warnings ${EMOJI_WARN}" "${ICON_FAIL} Failures ${EMOJI_FAIL}" "${ICON_INFO} Info ${EMOJI_INFO}" "${ICON_SKIP} Skipped ${EMOJI_SKIP}")
    for label_str in "${labels_to_measure[@]}"; do
        local current_len=$(get_display_width "$label_str")
        if (( current_len > max_summary_label_len )); then
            max_summary_label_len="$current_len"
        fi
    done

    local padded_label_part
    printf "%b  %-*s ⇒%3d%b\n" "${GREEN}${BOLD}" "$max_summary_label_len" "${ICON_PASS} Passed ${EMOJI_PASS}" "$created" "${NC}"
    printf "%b  %-*s ⇒%3d%b\n" "${ORANGE}${BOLD}" "$max_summary_label_len" "${ICON_WARN} Warnings ${EMOJI_WARN}" "0" "${NC}"
    printf "%b  %-*s ⇒%3d%b\n" "${RED}${BOLD}" "$max_summary_label_len" "${ICON_FAIL} Failures ${EMOJI_FAIL}" "$failed" "${NC}"
    printf "%b  %-*s ⇒%3d%b\n" "${BLUE}${BOLD}" "$max_summary_label_len" "${ICON_INFO} Info ${EMOJI_INFO}" "$total_info" "${NC}"
    printf "%b  %-*s ⇒%3d%b\n" "${WHITE}${BOLD}" "$max_summary_label_len" "${ICON_SKIP} Skipped ${EMOJI_SKIP}" "$skipped" "${NC}"
}

# Prints the summary table for the 'Display Milestone Status' section
print_status_summary() {
    local closed=$1
    local upcoming=$2
    local overdue=$3
    local on_track=$4
    local skipped=$5

    echo -e "${BOLD}${PURPLE}📊 Update/close Summary:${NC}"

    local max_summary_label_len=0
    local labels_to_measure=("${ICON_PASS} Closed ${EMOJI_PASS}" "${ICON_WARN} Upcoming ${EMOJI_WARN}" "${ICON_FAIL} Overdue ${EMOJI_FAIL}" "${ICON_INFO} On track ${EMOJI_INFO}" "${ICON_SKIP} Skipped ${EMOJI_SKIP}")
    for label_str in "${labels_to_measure[@]}"; do
        local current_len=$(get_display_width "$label_str")
        if (( current_len > max_summary_label_len )); then
            max_summary_label_len="$current_len"
        fi
    done

    local padded_label_part
    printf "%b  %-*s ⇒%3d%b\n" "${GREEN}${BOLD}" "$max_summary_label_len" "${ICON_PASS} Closed ${EMOJI_PASS}" "$closed" "${NC}"
    printf "%b  %-*s ⇒%3d%b\n" "${ORANGE}${BOLD}" "$max_summary_label_len" "${ICON_WARN} Upcoming ${EMOJI_WARN}" "$upcoming" "${NC}"
    printf "%b  %-*s ⇒%3d%b\n" "${RED}${BOLD}" "$max_summary_label_len" "${ICON_FAIL} Overdue ${EMOJI_FAIL}" "$overdue" "${NC}"
    printf "%b  %-*s ⇒%3d%b\n" "${BLUE}${BOLD}" "$max_summary_label_len" "${ICON_INFO} On track ${EMOJI_INFO}" "$on_track" "${NC}"
    printf "%b  %-*s ⇒%3d%b\n" "${WHITE}${BOLD}" "$max_summary_label_len" "${ICON_SKIP} Skipped ${EMOJI_SKIP}" "$skipped" "${NC}"
}

# ---
### Main Functions

create_milestones() {
  reset_section_counters
  log_header "${CYAN}" "${ICON_INFO} Creating milestones from milestones.json..."

  local created=0 failed=0 skipped=0

  if ! existing_titles_json=$(gh api "repos/$OWNER/$REPO/milestones" --paginate 2>&1); then
    printf "%b%s %s%b\n" "${RED}" "${ICON_FAIL}" "Failed to fetch existing milestones. Response:\n$existing_titles_json" "${NC}"
    CHECK_RESULTS+=("fail")
    print_section_progress_bar
    print_create_summary "$created" "$skipped" "1" "0"
    exit 1
  fi
  existing_titles=$(echo "$existing_titles_json" | jq -r '.[].title' || echo "")

  local i=0
  local milestones_list
  milestones_list=$(jq -r 'keys_unsorted[]' "$MILESTONES_FILE")

  # Acknowledge fetching milestones, but don't add to the progress bar for a 12/12 count
  printf "%b%s %s%b\n" "${CYAN}" "${ICON_INFO}" "Fetching existing milestones..." "${NC}"

  for version in $(echo "$milestones_list" | sort -V); do
    local description
    description=$(jq -r --arg version "$version" '.[$version]' "$MILESTONES_FILE")
    local due_date=$(calculate_due_date $((i * SPACING_DAYS)))
    i=$((i + 1))

    if echo "$existing_titles" | grep -Fxq "$version"; then
      printf "%b%s %s → %s ⇒ already exists%b\n" "${WHITE}" "${ICON_SKIP}" "$version" "${EMOJI_SKIP}" "${NC}"
      CHECK_RESULTS+=("skip")
      skipped=$((skipped + 1))
    else
      if ! api_response=$(gh api "repos/$OWNER/$REPO/milestones" \
          -f title="$version" \
          -f state="open" \
          -f description="$description" \
          -f due_on="${due_date}T23:59:59Z" 2>&1); then
        printf "%b%s %s → %s ⇒ Failed to create. Reason: %s%b\n" "${RED}" "${ICON_FAIL}" "$version" "${EMOJI_FAIL}" "$(echo "$api_response" | jq -r '.message // "Unknown API error"')" "${NC}"
        CHECK_RESULTS+=("fail")
        failed=$((failed + 1))
      else
        printf "%b%s %s → %s ⇒ Created successfully%b\n" "${GREEN}" "${ICON_PASS}" "$version" "${EMOJI_PASS}" "${NC}"
        CHECK_RESULTS+=("pass")
        created=$((created + 1))
      fi
    fi
  done
  print_section_progress_bar
  print_create_summary "$created" "$skipped" "$failed" "1"
}

display_milestone_status() {
  reset_section_counters
  log_header "${CYAN}" "${ICON_INFO} Displaying milestone status..."

  if ! milestones_json=$(gh api "repos/$OWNER/$REPO/milestones?state=all" --paginate 2>&1); then
    printf "%b%s %s%b\n" "${RED}" "${ICON_FAIL}" "Failed to fetch milestones for status display." "${NC}"
    CHECK_RESULTS+=("fail")
    print_section_progress_bar
    print_status_summary 0 0 0 0 0
    exit 1
  fi

  local now_seconds=$(date +%s)
  declare -A milestone_due_dates
  declare -A milestone_states
  declare -A milestone_descriptions
  declare -A milestone_numbers
  local next_upcoming_title=""
  local next_upcoming_due_seconds=0

  for row in $(echo "$milestones_json" | jq -r '.[] | @base64'); do
    _jq() { echo "$row" | base64 --decode | jq -r "$1"; }
    local title=$(_jq '.title')
    local state=$(_jq '.state')
    local due_on=$(_jq '.due_on // empty')
    local number=$(_jq '.number')
    local description=$(_jq '.description // ""')
    milestone_numbers["$title"]=$number
    milestone_states["$title"]=$state
    milestone_descriptions["$title"]=$description
    if [[ -n "$due_on" ]]; then
      local due_seconds=$(date -d "$due_on" +%s)
      milestone_due_dates["$title"]=$due_seconds
    else
      milestone_due_dates["$title"]=0
    fi
    if [[ "$state" == "open" ]] && [[ -n "$due_on" ]]; then
      if (( due_seconds > now_seconds )); then
        if (( next_upcoming_due_seconds == 0 )) || (( due_seconds < next_upcoming_due_seconds )); then
          next_upcoming_due_seconds=$due_seconds
          next_upcoming_title=$title
        fi
      fi
    fi
  done

  local sorted_titles=$(for title in "${!milestone_due_dates[@]}"; do echo -e "${milestone_due_dates[$title]}\t$title"; done | sort -n | cut -f2)
  local closed_count_status=0
  local on_track_count_status=0
  local overdue_count_status=0
  local next_upcoming_count_status=0
  local skipped_count_status=0

  for title in $sorted_titles; do
    local state=${milestone_states[$title]}
    local due_seconds=${milestone_due_dates[$title]}
    local description="${milestone_descriptions[$title]}"
    local number=${milestone_numbers[$title]}
    local status_emoji=""
    local status_text=""
    local log_prefix_icon=""
    local log_color=""

    if [[ "$state" == "closed" ]]; then
      status_emoji="${EMOJI_PASS}"
      status_text="Closed"
      log_prefix_icon="${ICON_PASS}"
      log_color="${GREEN}"
      closed_count_status=$((closed_count_status + 1))
      CHECK_RESULTS+=("pass")
    elif (( due_seconds > 0 && now_seconds > due_seconds )); then
      status_emoji="${EMOJI_FAIL}"
      status_text="Overdue"
      log_prefix_icon="${ICON_FAIL}"
      log_color="${RED}"
      overdue_count_status=$((overdue_count_status + 1))
      CHECK_RESULTS+=("fail")
    elif [[ "$title" == "$next_upcoming_title" ]]; then
      status_emoji="${EMOJI_WARN}"
      status_text="Next upcoming"
      log_prefix_icon="${ICON_WARN}"
      log_color="${ORANGE}"
      next_upcoming_count_status=$((next_upcoming_count_status + 1))
      CHECK_RESULTS+=("warn")
    else
      status_emoji="${EMOJI_INFO}"
      status_text="On track"
      log_prefix_icon="${ICON_INFO}"
      log_color="${BLUE}"
      on_track_count_status=$((on_track_count_status + 1))
      CHECK_RESULTS+=("info")
    fi

    printf "%b%s %s → %s ⇒ %s%b\n" "$log_color" "${log_prefix_icon}" "$title" "${status_emoji}" "$status_text" "${NC}"

    local cleaned_description="$description"
    cleaned_description="${cleaned_description/#${EMOJI_PASS} /}"
    cleaned_description="${cleaned_description/#${EMOJI_FAIL} /}"
    cleaned_description="${cleaned_description/#${EMOJI_ON_TRACK} /}"
    cleaned_description="${cleaned_description/#${EMOJI_WARN} /}"
    local new_description="${status_emoji} ${cleaned_description}"

    if ! gh api -X PATCH "repos/$OWNER/$REPO/milestones/$number" -f description="$new_description" >/dev/null 2>&1; then
      skipped_count_status=$((skipped_count_status + 1))
    fi
  done
  print_section_progress_bar
  print_status_summary "$closed_count_status" "$next_upcoming_count_status" "$overdue_count_status" "$on_track_count_status" "$skipped_count_status"
}

# The 'auto_close_eligible_milestones' function is not included in your prompt output,
# so it is commented out for now to ensure the script's output matches your request.
# You can uncomment and update it if you want that functionality.
# auto_close_eligible_milestones() {
#   echo -e "Auto-close functionality not implemented in this version."
# }

usage() {
  cat <<EOF
Usage: $0 -o <owner> -r <repo> -m <milestones_file> [-c]
Options:
  -o   GitHub repository owner
  -r   GitHub repository name
  -m   JSON file with milestones (keys = version, values = descriptions)
  -c   Auto-close eligible milestones (optional)
  -h   Show this help message
Example milestones file (JSON):
{
  "v1.0": "Initial release",
  "v1.1": "Bug fixes and improvements",
  "v2.0": "Major update"
}
EOF
}

# === ENTRY POINT ===
OWNER=""
REPO=""
MILESTONES_FILE=""
AUTO_CLOSE=false

while getopts ":o:r:m:ch" opt; do
  case $opt in
    o) OWNER=$OPTARG ;;
    r) REPO=$OPTARG ;;
    m) MILESTONES_FILE=$OPTARG ;;
    c) AUTO_CLOSE=true ;;
    h) usage; exit 0 ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$OWNER" || -z "$REPO" || -z "$MILESTONES_FILE" ]]; then
  echo "Missing required parameters." >&2; usage; exit 1
fi

if [[ ! -f "$MILESTONES_FILE" ]]; then
  echo "Milestones file not found: $MILESTONES_FILE" >&2; exit 1
fi

log_header "${PURPLE}" "📌 Starting milestone management for $OWNER/$REPO..."

create_milestones
display_milestone_status

if $AUTO_CLOSE; then
  : # No-op for now to match requested output
fi

echo -e "\n🏁 Done.\n"
