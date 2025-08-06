#!/bin/bash
set -euo pipefail

# === COLORS & ICONS ===
GREEN='\033[1;32m'
ORANGE='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;37m'
BLUE='\033[1;34m'
BLACK='\033[1;30m' # Added BLACK color code
BOLD='\033[1m'
NC='\033[0m'

# Icons without embedded color codes; colors are applied by log functions or printf
ICON_PASS="✓"
ICON_FAIL="✗"
ICON_WARN="💡"
ICON_INFO="ℹ"
ICON_SKIP="➤"

declare -A CHECKS_COUNT=( ["pass"]=0 ["warn"]=0 ["info"]=0 ["skip"]=0 ["fail"]=0 )
declare -a CHECK_RESULTS

# === HELPERS ===
get_display_width() {
    echo -n "$1" | wc -m
}

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
log_success() {
    printf "%b%s %s%b\n" "${GREEN}" "${ICON_PASS}" "$1" "${NC}"
    CHECKS_COUNT[pass]=$((CHECKS_COUNT[pass]+1))
    CHECK_RESULTS+=("pass")
}
log_error() {
    printf "%b%s %s%b\n" "${RED}" "${ICON_FAIL}" "$1" "${NC}"
    CHECKS_COUNT[fail]=$((CHECKS_COUNT[fail]+1))
    CHECK_RESULTS+=("fail")
    exit 1
}
log_skip() {
    # Changed log color for skipped checks to BLACK
    printf "%b%s %s%b\n" "${BLACK}" "${ICON_SKIP}" "$1" "${NC}"
    CHECKS_COUNT[skip]=$((CHECKS_COUNT[skip]+1))
    CHECK_RESULTS+=("skip")
}

# ---
### Progress Bar and Summary

The `print_progress_summary` function has been updated to use the black square emoji (`⬛`) for skipped checks and to apply the correct `BLACK` color code in the summary printout.

```bash
# === PROGRESS BAR ===
print_progress_summary() {
    local total=${#CHECK_RESULTS[@]}
    local bar=""

    for result in "${CHECK_RESULTS[@]}"; do
        case "$result" in
            "pass") bar+="🟩";;
            "warn") bar+="🟧";;
            "skip") bar+="⬛";; # Changed to a black square emoji
            "fail") bar+="🟥";;
            "info") bar+="🟦";;
        esac
    done

    echo -e "\n"
    echo -e "${BOLD}Progress: [${bar}] 100% ($total/$total checks)${NC}"
    echo -e "\n"

    echo -e "${BOLD}📊 Summary:${NC}"

    local max_summary_label_len=0
    local labels_to_measure=("${ICON_PASS} Passed" "${ICON_WARN} Warnings" "${ICON_SKIP} Skipped" "${ICON_FAIL} Failures" "${ICON_INFO} Info")
    for label_str in "${labels_to_measure[@]}"; do
        local current_len=$(get_display_width "$label_str")
        if (( current_len > max_summary_label_len )); then
            max_summary_label_len="$current_len"
        fi
    done
    max_summary_label_len=$((max_summary_label_len + 2))

    local padded_label_part

    # Passed line
    local label_text="${ICON_PASS} Passed"
    local current_label_display_len=$(get_display_width "$label_text")
    local padding_needed=$((max_summary_label_len - current_label_display_len))
    padded_label_part="${label_text}"
    for ((i=0; i<padding_needed; i++)); do padded_label_part+=" "; done
    printf "%b  %s%3d%b\n" "${GREEN}${BOLD}" "$padded_label_part" "${CHECKS_COUNT[pass]}" "${NC}"

    # Warnings line
    label_text="${ICON_WARN} Warnings"
    current_label_display_len=$(get_display_width "$label_text")
    padding_needed=$((max_summary_label_len - current_label_display_len))
    padded_label_part="${label_text}"
    for ((i=0; i<padding_needed; i++)); do padded_label_part+=" "; done
    printf "%b  %s%3d%b\n" "${ORANGE}${BOLD}" "$padded_label_part" "${CHECKS_COUNT[warn]}" "${NC}"

    # Skipped line - Updated color to BLACK
    label_text="${ICON_SKIP} Skipped"
    current_label_display_len=$(get_display_width "$label_text")
    padding_needed=$((max_summary_label_len - current_label_display_len))
    padded_label_part="${label_text}"
    for ((i=0; i<padding_needed; i++)); do padded_label_part+=" "; done
    printf "%b  %s%3d%b\n" "${BLACK}${BOLD}" "$padded_label_part" "${CHECKS_COUNT[skip]}" "${NC}"

    # Failures line
    label_text="${ICON_FAIL} Failures"
    current_label_display_len=$(get_display_width "$label_text")
    padding_needed=$((max_summary_label_len - current_label_display_len))
    padded_label_part="${label_text}"
    for ((i=0; i<padding_needed; i++)); do padded_label_part+=" "; done
    printf "%b  %s%3d%b\n" "${RED}${BOLD}" "$padded_label_part" "${CHECKS_COUNT[fail]}" "${NC}"

    # Info line
    label_text="${ICON_INFO} Info"
    current_label_display_len=$(get_display_width "$label_text")
    padding_needed=$((max_summary_label_len - current_label_display_len))
    padded_label_part="${label_text}"
    for ((i=0; i<padding_needed; i++)); do padded_label_part+=" "; done
    printf "%b  %s%3d%b\n" "${BLUE}${BOLD}" "$padded_label_part" "${CHECKS_COUNT[info]}" "${NC}"
}
