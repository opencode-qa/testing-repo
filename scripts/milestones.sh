#!/bin/bash
# Refactored GitHub Milestone Automation Script
set -euo pipefail

# === CONFIGURATION ===
START_DATE="2025-08-06" # The start date for the first milestone's due date
SPACING_DAYS=3          # Days between each milestone's due date

# GitHub authentication
GITHUB_TOKEN="${GH_PAT:-${GITHUB_TOKEN:-}}"
if [[ -z "$GITHUB_TOKEN" ]]; then
  echo -e "🔴 \033[1;31mERROR: GITHUB_TOKEN not set\033[0m"
  exit 1
fi

# === COLORS & ICONS ===
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

ICON_SUCCESS="🟢"
ICON_ON_TRACK="⚪"
ICON_OVERDUE="🔴"
ICON_PROCESSING="🟡"
ICON_NEXT_UPCOMING="🟠"

# Function to print a status line with a colored icon and message
print_status_line() {
  local version=$1 icon=$2 color_code=$3 status_text=$4
  printf "%b✔ %s → %s ⇒ %s%b\n" "$color_code" "$version" "$icon" "$status_text" "$NC"
}

# Function to print a progress bar
print_progress_bar() {
  local progress=$1 total=$2 width=30
  if (( total > 0 )); then
    local percentage=$(( progress * 100 / total ))
    local filled=$(( (percentage * width + 50) / 100 ))
    local empty=$((width - filled))
    local bar=$(printf "%0.s█" $(seq 1 $filled))
    local spaces=$(printf "%0.s░" $(seq 1 $empty))
    echo -e "[${bar}${spaces}] ${percentage}%%"
  fi
}

# Function to calculate a milestone's due date
calculate_due_date() {
  date -d "$START_DATE +$1 days" +"%Y-%m-%d"
}

# === MAIN FUNCTIONS ===

create_milestones() {
  echo -e "\n🚀 Creating milestones from $MILESTONES_FILE..."
  echo "Fetching existing milestones..."

  if ! existing_titles_json=$(gh api "repos/$OWNER/$REPO/milestones" --paginate 2>&1); then
    echo -e "🔴 \033[1;31mERROR: Failed to fetch existing milestones. Response:\n$existing_titles_json\033[0m"
    exit 1
  fi
  existing_titles=$(echo "$existing_titles_json" | jq -r '.[].title' || echo "")

  local i=0 created=0 failed=0 skipped=0
  local milestones_list
  milestones_list=$(jq -r 'keys_unsorted[]' "$MILESTONES_FILE")
  local total_milestones=$(echo "$milestones_list" | wc -l | xargs)

  for version in $(echo "$milestones_list" | sort -V); do
    local description
    description=$(jq -r --arg version "$version" '.[$version]' "$MILESTONES_FILE")
    local due_date=$(calculate_due_date $((i * SPACING_DAYS)))
    i=$((i + 1))

    if echo "$existing_titles" | grep -Fxq "$version"; then
      print_status_line "$version" "$ICON_ON_TRACK" "$WHITE" "Already exists"
      skipped=$((skipped + 1))
    else
      if ! api_response=$(gh api "repos/$OWNER/$REPO/milestones" \
          -f title="$version" \
          -f state="open" \
          -f description="$description" \
          -f due_on="${due_date}T23:59:59Z" 2>&1); then
        local error_reason=$(echo "$api_response" | jq -r '.message // "Unknown API error"')
        print_status_line "$version" "$ICON_OVERDUE" "$RED" "Failed to create. Reason: $error_reason"
        failed=$((failed + 1))
      else
        print_status_line "$version" "$ICON_SUCCESS" "$GREEN" "Created successfully"
        created=$((created + 1))
      fi
    fi
  done
  print_progress_bar "$total_milestones" "$total_milestones"
  echo -e "\n📊 Create Summary:"
  echo -e "  ${GREEN}Created: $created${NC}"
  echo -e "  ${WHITE}Skipped: $skipped${NC}"
  if (( failed > 0 )); then
    echo -e "  ${RED}Failed: $failed${NC}"
  fi
}

display_milestone_status() {
  echo -e "\n🛠 Displaying milestone status..."

  if ! milestones_json=$(gh api "repos/$OWNER/$REPO/milestones?state=all" --paginate 2>&1); then
    echo -e "🔴 \033[1;31mERROR: Failed to fetch milestones for status display. Response:\n$milestones_json\033[0m"
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
      local due_seconds
      due_seconds=$(date -d "$due_on" +%s)
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

  local sorted_titles
  sorted_titles=$(for title in "${!milestone_due_dates[@]}"; do
    echo -e "${milestone_due_dates[$title]}\t$title"
  done | sort -n | cut -f2)

  local count=0 closed_count=0 on_track_count=0 overdue_count=0 next_upcoming_count=0

  for title in $sorted_titles; do
    count=$((count + 1))
    local state=${milestone_states[$title]}
    local due_seconds=${milestone_due_dates[$title]}
    local description="${milestone_descriptions[$title]}"
    local number=${milestone_numbers[$title]}

    local icon=""
    local status_text=""

    if [[ "$state" == "closed" ]]; then
      icon="$ICON_SUCCESS"
      status_text="Closed"
      closed_count=$((closed_count + 1))
    elif [[ "$title" == "$next_upcoming_title" ]]; then
      icon="$ICON_NEXT_UPCOMING"
      status_text="Next upcoming"
      next_upcoming_count=$((next_upcoming_count + 1))
    elif (( due_seconds > 0 && now_seconds > due_seconds )); then
      icon="$ICON_OVERDUE"
      status_text="Overdue"
      overdue_count=$((overdue_count + 1))
    else
      icon="$ICON_ON_TRACK"
      status_text="On track"
      on_track_count=$((on_track_count + 1))
    fi

    print_status_line "$title" "$icon" "$WHITE" "$status_text"

    # Update milestone description on GitHub
    # Only prepend emoji (no status text) to description
    # Avoid duplicate emoji if already present
    if [[ "$description" != "$icon "* ]]; then
      # Remove any existing status emojis from the start
      local cleaned_description="$description"
      cleaned_description="${cleaned_description/#🟢 /}"
      cleaned_description="${cleaned_description/#🔴 /}"
      cleaned_description="${cleaned_description/#⚪ /}"
      cleaned_description="${cleaned_description/#🟠 /}"

      local new_description="${icon} ${cleaned_description}"

      if ! gh api -X PATCH "repos/$OWNER/$REPO/milestones/$number" \
        -f description="$new_description" >/dev/null 2>&1; then
        echo -e "⚠️ Warning: Failed to update milestone description for $title"
      fi
    fi
  done

  print_progress_bar "$count" "$count"

  echo -e "\n📊 Status Summary:"
  echo -e "  ${GREEN}Closed: $closed_count${NC}"
  echo -e "  🟠 Next upcoming: $next_upcoming_count"
  echo -e "  ${RED}Overdue: $overdue_count${NC}"
  echo -e "  ${WHITE}On track: $on_track_count${NC}"
}

auto_close_eligible_milestones() {
  echo -e "\n🔒 Auto-closing eligible milestones..."

  if ! milestones_json=$(gh api "repos/$OWNER/$REPO/milestones?state=open" --paginate 2>&1); then
    echo -e "🔴 \033[1;31mERROR: Failed to fetch open milestones for auto-closing. Response:\n$milestones_json\033[0m"
    exit 1
  fi

  local total_open=$(echo "$milestones_json" | jq length)
  local closed=0 skipped=0

  if (( total_open == 0 )); then
    echo "No open milestones to check."
    print_progress_bar 0 0
    return
  fi

  local now_seconds=$(date +%s)
  local count=0

  for row in $(echo "$milestones_json" | jq -r '.[] | @base64'); do
    _jq() { echo "$row" | base64 --decode | jq -r "$1"; }
    count=$((count + 1))

    local title=$(_jq '.title')
    local due_on=$(_jq '.due_on // empty')
    local number=$(_jq '.number')
    local open_issues=$(_jq '.open_issues')
    local closed_issues=$(_jq '.closed_issues')
    local state=$(_jq '.state')

    if [[ "$state" != "open" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    if [[ -z "$due_on" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    local due_seconds=$(date -d "$due_on" +%s)

    if (( due_seconds < now_seconds )); then
      # Auto-close only if open_issues is zero (or optionally closed issues match total issues)
      if (( open_issues == 0 )); then
        if gh api -X PATCH "repos/$OWNER/$REPO/milestones/$number" -f state="closed" >/dev/null 2>&1; then
          echo -e "✅ Closed milestone: $title"
          closed=$((closed + 1))
        else
          echo -e "⚠️ Failed to close milestone: $title"
        fi
      else
        skipped=$((skipped + 1))
      fi
    else
      skipped=$((skipped + 1))
    fi
  done

  print_progress_bar "$closed" "$total_open"
  echo -e "\n📊 Auto-close Summary:"
  echo -e "  ${GREEN}Closed: $closed${NC}"
  echo -e "  ${WHITE}Skipped: $skipped${NC}"
}

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
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      usage
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$OWNER" || -z "$REPO" || -z "$MILESTONES_FILE" ]]; then
  echo "Missing required parameters." >&2
  usage
  exit 1
fi

if [[ ! -f "$MILESTONES_FILE" ]]; then
  echo "Milestones file not found: $MILESTONES_FILE" >&2
  exit 1
fi

echo -e "\n📌 Starting milestone management for $OWNER/$REPO..."

create_milestones
display_milestone_status

if $AUTO_CLOSE; then
  auto_close_eligible_milestones
fi

echo -e "\n🏁 Done.\n"
