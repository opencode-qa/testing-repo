#!/bin/bash

BLUE='\033[1;34m'
GREEN='\033[1;32m'
RED='\033[1;31m'
ORANGE='\033[38;5;214m'
NC='\033[0m'

INFO_ICON="${BLUE}🔵${NC}"
PASS_ICON="${GREEN}✓${NC}"
FAIL_ICON="${RED}✗${NC}"
PROCESS_ICON="${ORANGE}🟠${NC}"

completed_steps=0
TOTAL_STEPS=5

show_progress_bar() {
  local done_steps=$1
  local bar_length=20
  local done_length=$((done_steps * bar_length / TOTAL_STEPS))
  local left_length=$((bar_length - done_length))

  local done_bar=$(printf '🟩%.0s' $(seq 1 $done_length))
  local left_bar=$(printf '⬜%.0s' $(seq 1 $left_length))
  printf "\rProgress: [%s%s] %d%% (%d/%d)\n" "$done_bar" "$left_bar" $((done_steps * 100 / TOTAL_STEPS)) "$done_steps" "$TOTAL_STEPS"
}

print_step() {
  local icon=$1
  local message=$2
  echo -e "${icon} ${message}${NC}"
  ((completed_steps++))
  show_progress_bar $completed_steps
}

print_step "$INFO_ICON" "Starting the script"
print_step "$PROCESS_ICON" "Running checks"
print_step "$PASS_ICON" "Checks passed"
print_step "$FAIL_ICON" "An error occurred"
print_step "$PASS_ICON" "Script finished"
