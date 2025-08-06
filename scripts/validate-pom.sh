#!/usr/bin/env bash
# Ultimate POM Validator v3.0 - Final Perfect Edition

# === CONFIGURATION ===
POM_FILE="${POM_FILE:-pom.xml}"
REPORTS_DIR="${REPORTS_DIR:-../Reports}" # Goes in parent repository's Reports folder
HTML_REPORT="${HTML_REPORT:-true}"
DEPENDENCY_GRAPH="${DEPENDENCY_GRAPH:-false}"
STRICT_MODE="${STRICT_MODE:-false}"
VERBOSE="${VERBOSE:-false}"

# === COLOR THEME ===
GREEN='\033[1;32m'
ORANGE='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;37m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color - Resets all attributes

# === EMOJI ICONS ===
PASS_ICON="🟢"
WARN_ICON="🟠"
FAIL_ICON="🔴"
INFO_ICON="🔵"
ARROW_ICON="→"
RESULT_ICON="⇒"

# === MILESTONE MAP ===
declare -A MILESTONE_MAP=(
  ["v0.0.0"]="Initial Setup"
  ["v0.1.0"]="Basic Testing"
  ["v0.2.0"]="CI Integration"
  ["v0.3.0"]="Logging Setup"
  ["v0.4.0"]="Exception Handling"
  ["v0.5.0"]="Driver Management"
  ["v0.6.0"]="POM Structure"
  ["v0.7.0"]="Wait Utilities"
  ["v0.8.0"]="Screenshot Support"
  ["v0.9.0"]="TestNG Listeners"
  ["v1.0.0"]="Allure Reporting"
  ["v1.1.0"]="Retry Mechanism"
)

# === VERSION REQUIREMENTS ===
declare -A VERSION_REQUIREMENTS=(
  ["selenium-java"]="4.0.0"
  ["testng"]="7.0.0"
  ["log4j-core"]="2.0.0"
  ["allure-testng"]="2.0.0"
  ["webdrivermanager"]="5.0.0"
  ["maven-surefire-plugin"]="3.0.0"
  ["java.version"]="17"
)

# === CHECK REGISTRY ===
declare -A CHECK_FUNCS=(
    [encoding]=check_encoding
    [dependencies]=check_dependencies
    [plugins]=check_plugins
    [java]=check_java_version
    [properties]=check_properties
    [structure]=check_structure
    [repositories]=check_repositories
    [build]=check_build_config
)

declare -a DEFAULT_CHECKS=(
    "encoding"
    "java"
    "dependencies"
    "plugins"
    "properties"
    "structure"
    "repositories"
    "build"
)

# === TRACKING ===
declare -A counts=( ["pass"]=0 ["warn"]=0 ["fail"]=0 ["info"]=0 )
# Stores results for deferred printing: "status|category|item|message"
declare -a ALL_RESULTS=()
completed_checks=0
total_checks=0
start_time=$(date +%s)
CHECK_STATUS_ARRAY=()

# === UTILITY FUNCTIONS ===
# Function to get display width of a string (handles multi-byte chars/emojis)
get_display_width() {
    echo -n "$1" | wc -m
}

validate_xml() {
    if ! xmllint --noout "$POM_FILE" 2>/dev/null; then
        echo -e "${RED}${BOLD}✗ Error: Invalid XML in $POM_FILE${NC}"
        exit 1
    fi
}

init_output_dir() {
    mkdir -p "$REPORTS_DIR"
    if [[ "$HTML_REPORT" == "true" ]]; then
        cat > "$REPORTS_DIR/pom-validation-report.html" <<HTML
<!DOCTYPE html>
<html>
<head>
    <title>POM Validation Report</title>
    <style>
        :root {
            --bg-color: #1e1e2e;
            --card-color: #2a2a3a;
            --text-color: #e0e0e0;
            --accent-color: #3498db;
            --pass-color: #27ae60;
            --warn-color: #f39c12;
            --fail-color: #e74c3c;
            --info-color: #3498db;
        }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: var(--bg-color);
            color: var(--text-color);
        }
        .summary-card {
            background: var(--card-color);
            border-radius: 8px;
            box-shadow: 0 4px 8px rgba(0,0,0,0.3);
            padding: 25px;
            margin-bottom: 25px;
        }
        h1 {
            color: var(--accent-color);
            margin-top: 0;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }
        th {
            background-color: var(--accent-color);
            color: white;
            padding: 12px;
            text-align: left;
        }
        td {
            padding: 12px;
            border-bottom: 1px solid #3a3a4a;
        }
        .pass { color: var(--pass-color) }
        .warn { color: var(--warn-color) }
        .fail { color: var(--fail-color) }
        .info { color: var(--info-color) }
        .progress-container {
            width: 100%;
            background-color: #3a3a4a;
            border-radius: 5px;
            margin: 20px 0;
            overflow: hidden;
        }
        .progress-bar {
            height: 24px;
            background: linear-gradient(90deg, var(--pass-color), var(--accent-color));
            text-align: center;
            line-height: 24px;
            color: white;
            transition: width 0.5s ease;
        }
        .status-icon {
            font-weight: bold;
            margin-right: 5px;
        }
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 15px;
            margin-top: 20px;
        }
        .summary-item {
            background: var(--card-color);
            border-radius: 8px;
            padding: 15px;
            text-align: center;
        }
        .summary-icon {
            font-size: 24px;
            display: block;
            margin-bottom: 5px;
        }
        .summary-count {
            font-size: 28px;
            font-weight: bold;
            display: block;
        }
        .execution-time {
            text-align: right;
            font-style: italic;
            margin-top: 20px;
            color: #a0a0a0;
        }
    </style>
</head>
<body>
    <div class="summary-card">
        <h1>POM Validation Report</h1>
        <p>Generated: $(date)</p>
        <p>Project Version: $(get_tag_value version)</p>
        <table>
            <thead>
                <tr>
                    <th>Category</th>
                    <th>Item</th>
                    <th>Status</th>
                    <th>Message</th>
                </tr>
            </thead>
            <tbody id="report-body">
            </tbody>
        </table>
    </div>
HTML
    fi
}

get_version_by_artifact_id() {
    local artifact=$1
    awk "/<artifactId>$artifact<\/artifactId>/,/<\/(plugin|dependency)>/" "$POM_FILE" \
        | grep -oP "<version>(.*?)</version>" \
        | sed -E 's|<version>(.*)</version>|\1|' | head -n1 || true
}

resolve_property() {
    local value=$1
    if [[ "$value" =~ ^\$\{(.+)\}$ ]]; then
        local key="${BASH_REMATCH[1]}"
        get_tag_value "$key"
    else
        echo "$value"
    fi
}

get_tag_value() {
    local tag=$1
    grep -oP "<$tag>(.*?)</$tag>" "$POM_FILE" | sed -E "s|.*<$tag>(.*)</$tag>.*|\1|" | head -n1 || true
}

version_ge() {
    [ "$1" = "$2" ] && return 0
    [ "$(printf "%s\n%s" "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# === CHECK FUNCTIONS ===
check_encoding() {
    local val=$(get_tag_value "project.build.sourceEncoding")
    if [[ "$val" == "UTF-8" ]]; then
        record_result "pass" "Encoding" "" "Proper encoding set"
    else
        record_result "warn" "Encoding" "" "Recommend UTF-8 encoding"
    fi
}

check_dependencies() {
    local issues=0
    for dep in "${!VERSION_REQUIREMENTS[@]}"; do
        [[ "$dep" == "java.version" ]] && continue

        local version=$(get_version_by_artifact_id "$dep")
        local resolved_version=$(resolve_property "$version")
        local required_version="${VERSION_REQUIREMENTS[$dep]}"

        if [[ -n "$resolved_version" ]]; then
            if version_ge "$resolved_version" "$required_version"; then
                record_result "pass" "Dependency" "$dep" "v$resolved_version (>= $required_version)"
            else
                record_result "fail" "Dependency" "$dep" "v$resolved_version (needs $required_version+)"
                ((issues++))
            fi
        else
            if [[ "$STRICT_MODE" == "true" && "$dep" != "log4j-core" && "$dep" != "allure-testng" ]]; then
                record_result "fail" "Dependency" "$dep" "Required dependency not found"
                ((issues++))
            else
                record_result "warn" "Dependency" "$dep" "Not found (optional)"
            fi
        fi
    done

    [[ $issues -eq 0 ]] && record_result "pass" "Dependencies" "All core" "Meet version requirements"
}

check_plugins() {
    local issues=0
    local plugins=("maven-surefire-plugin" "maven-compiler-plugin" "maven-clean-plugin")

    for plugin in "${plugins[@]}"; do
        local version=$(get_version_by_artifact_id "$plugin")
        local resolved_version=$(resolve_property "$version")

        if [[ -n "$resolved_version" ]]; then
            record_result "pass" "Plugin" "$plugin" "v$resolved_version"
        else
            record_result "warn" "Plugin" "$plugin" "Not configured"
            ((issues++))
        fi
    done

    [[ $issues -eq 0 ]] && record_result "pass" "Plugins" "All core" "Properly configured"
}

check_java_version() {
    local version=$(get_tag_value "java.version")
    local required_version="${VERSION_REQUIREMENTS["java.version"]}"

    if [[ -n "$version" ]]; then
        if version_ge "$version" "$required_version"; then
            record_result "pass" "Java" "Version" "$version (>= $required_version)"
        else
            record_result "fail" "Java" "Version" "$version (needs $required_version+)"
        fi
    else
        record_result "warn" "Java" "Version" "Not specified (recommend $required_version+)"
    fi
}

check_properties() {
    local properties_count=$(grep -c "<properties>" "$POM_FILE")
    if (( properties_count > 0 )); then
        record_result "pass" "Properties" "Section" "Found"
    else
        record_result "warn" "Properties" "Section" "Missing"
    fi
}

check_structure() {
    local issues=0
    local required_sections=("modelVersion" "groupId" "artifactId" "version" "dependencies")

    for section in "${required_sections[@]}"; do
        if grep -q "<$section>" "$POM_FILE"; then
            record_result "pass" "Structure" "$section" "Found"
        else
            record_result "fail" "Structure" "$section" "Missing"
            ((issues++))
        fi
    done

    [[ $issues -eq 0 ]] && record_result "pass" "Structure" "All required" "Sections present"
}

check_repositories() {
    local repos_count=$(awk '/<repositories>/,/<\/repositories>/' "$POM_FILE" | grep -c "<repository>")
    if (( repos_count > 0 )); then
        record_result "info" "Repositories" "Count" "$repos_count found"
    else
        record_result "info" "Repositories" "Custom" "None defined"
    fi
}

check_build_config() {
    local build_sections=("plugins" "resources" "testResources")
    local issues=0

    for section in "${build_sections[@]}"; do
        if grep -q "<$section>" "$POM_FILE"; then
            record_result "pass" "Build" "$section" "Configured"
        else
            record_result "info" "Build" "$section" "Not configured"
            ((issues++))
        fi
    done

    [[ $issues -eq 0 ]] && record_result "pass" "Build" "All sections" "Properly configured"
}

# === PROGRESS BAR ===
show_progress() {
    local current=$1 total=$2 statuses=("${!3}")
    [[ $total -eq 0 ]] && return

    local bar=""
    for status in "${statuses[@]}"; do
        case "$status" in
            pass) bar+="🟩" ;;
            warn) bar+="🟧" ;; # Changed from 🟨 to 🟧
            fail) bar+="🟥" ;;
            info) bar+="🟦" ;;
            *) bar+="⬛" ;;
        esac
    done

    local percent=$((100 * current / total))
    echo -ne "\r  [${bar}] ${percent}% (${current}/${total} checks)"
}

# === RESULT HANDLING ===
record_result() {
    local status=$1 category=$2 item=$3 message=$4
    ((counts["$status"]++))
    ((completed_checks++))
    CHECK_STATUS_ARRAY+=("$status")

    # Store result for deferred, aligned printing
    ALL_RESULTS+=("$status|$category|$item|$message")

    # Add to HTML report
    if [[ "$HTML_REPORT" == "true" ]]; then
        local icon
        case "$status" in
            pass) icon="$PASS_ICON" ;;
            warn) icon="$WARN_ICON" ;;
            fail) icon="$FAIL_ICON" ;;
            info) icon="$INFO_ICON" ;;
        esac
        sed -i "/id=\"report-body\"/a \
            <tr class=\"$status\">\
            <td>$category</td>\
            <td>$item</td>\
            <td class=\"$status\"><span class=\"status-icon\">$icon</span> $status</td>\
            <td>$message</td>\
            </tr>" "$REPORTS_DIR/pom-validation-report.html"
    fi
}

print_aligned_results() {
    local max_cat_len=0
    local max_item_len=0

    # First pass: Determine maximum lengths for alignment
    for result_line in "${ALL_RESULTS[@]}"; do
        IFS='|' read -r status category item message <<< "$result_line"

        # Calculate the display length of "${prefix_icon_char} ${category}"
        local prefix_icon_char # e.g., "✓", "⚠"
        case "$status" in
            pass) prefix_icon_char="✓" ;;
            warn) prefix_icon_char="⚠" ;;
            fail) prefix_icon_char="✗" ;;
            info) prefix_icon_char="ℹ" ;;
        esac
        local formatted_category_display_str="${prefix_icon_char} ${category}"
        local current_formatted_cat_len=$(get_display_width "$formatted_category_display_str")

        # Calculate the display length of "$item"
        local current_item_len=$(get_display_width "$item")

        if (( current_formatted_cat_len > max_cat_len )); then
            max_cat_len="$current_formatted_cat_len"
        fi
        if (( current_item_len > max_item_len )); then
            max_item_len="$current_item_len"
        fi
    done

    # Ensure minimum widths for readability
    (( max_cat_len < 10 )) && max_cat_len=10
    (( max_item_len < 10 )) && max_item_len=10

    # Second pass: Print results with calculated alignment
    for result_line in "${ALL_RESULTS[@]}"; do
        IFS='|' read -r status category item message <<< "$result_line"
        local icon color prefix_icon

        case "$status" in
            pass) icon="$PASS_ICON"; color="$GREEN"; prefix_icon="✓" ;;
            warn) icon="$WARN_ICON"; color="$ORANGE"; prefix_icon="⚠" ;;
            fail) icon="$FAIL_ICON"; color="$RED"; prefix_icon="✗" ;;
            info) icon="$INFO_ICON"; color="$BLUE"; prefix_icon="ℹ" ;;
        esac

        # Manually pad category part
        local formatted_category_str="${prefix_icon} ${category}"
        local current_formatted_cat_display_len=$(get_display_width "$formatted_category_str")
        local cat_padding_needed=$((max_cat_len - current_formatted_cat_display_len))
        local padded_category_part="${formatted_category_str}"
        for ((i=0; i<cat_padding_needed; i++)); do
            padded_category_part+=" "
        done

        # Manually pad item part
        local current_item_display_len=$(get_display_width "$item")
        local item_padding_needed=$((max_item_len - current_item_display_len))
        local padded_item_part="${item}"
        for ((i=0; i<item_padding_needed; i++)); do
            padded_item_part+=" "
        done

        # Construct the full line content without color codes
        local full_line_content="  ${padded_category_part}  ${ARROW_ICON}  ${padded_item_part}  ${icon}  ${RESULT_ICON}  ${message}"

        # Print the line, applying color to the entire string and resetting at the end
        printf "${color}%s${NC}\n" "$full_line_content"
    done
}


generate_dependency_graph() {
    if [[ "$DEPENDENCY_GRAPH" != "true" ]]; then
        return
    fi

    if ! command -v dot &>/dev/null; then
        record_result "warn" "Dependency" "Graphviz" "Install 'dot' command for visualization"
        return
    fi

    local graph_file="$REPORTS_DIR/dependencies.dot"
    echo "digraph Dependencies {" > "$graph_file"
    echo "  node [shape=box, style=filled, color=lightblue];" >> "$graph_file"
    echo "  rankdir=LR;" >> "$graph_file"

    awk '/<dependency>/,/<\/dependency>/' "$POM_FILE" | \
    awk 'BEGIN{RS="<dependency>";FS="\n"} NR>1 {print $0}' | \
    while read -r dep; do
        group=$(echo "$dep" | grep -oP "<groupId>(.*?)</groupId>" | sed -E 's|<groupId>(.*)</groupId>|\1|')
        artifact=$(echo "$dep" | grep -oP "<artifactId>(.*?)</artifactId>" | sed -E 's|<artifactId>(.*)</artifactId>|\1|')
        version=$(echo "$dep" | grep -oP "<version>(.*?)</version>" | sed -E 's|<version>(.*)</version>|\1|')

        if [[ -n "$group" && -n "$artifact" ]]; then
            version=${version:-$(resolve_property "$version")}
            label="$artifact\n${version:-unknown}"
            echo "  \"$group:$artifact\" [label=\"$label\"];" >> "$graph_file"
        fi
    done

    echo "}" >> "$graph_file"

    if dot -Tpng "$graph_file" -o "$REPORTS_DIR/dependencies.png" 2>/dev/null; then
        record_result "info" "Dependency" "Graph" "Generated $REPORTS_DIR/dependencies.png"
        if [[ "$HTML_REPORT" == "true" ]]; then
            echo "<h2>Dependency Graph</h2><img src=\"dependencies.png\" alt=\"Dependency Graph\" style=\"max-width:100%;border-radius:8px;margin-top:20px;\">" >> "$REPORTS_DIR/pom-validation-report.html"
        fi
    else
        record_result "warn" "Dependency" "Graph" "Generation failed"
    fi
}

print_header() {
    echo -e "${PURPLE}"
    echo -e "╔════════════════════════════════════════════════════╗"
    echo -e "║  🚀  POM VALIDATOR v3.0  -  $(date +"%Y-%m-%d %H:%M")      ║"
    echo -e "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_help() {
    echo -e "${BOLD}Usage:${NC} $0 [options]"
    echo -e "Options:"
    echo -e "  --strict       : Enable strict mode (treat warnings as errors)"
    echo -e "  --html         : Generate HTML report (default: true)"
    echo -e "  --no-html      : Disable HTML report generation"
    echo -e "  --graph        : Generate dependency graph (requires Graphviz)"
    echo -e "  --output DIR   : Set output directory (default: ../Reports)"
    echo -e "  --verbose      : Show detailed output"
    echo -e "  --list-checks  : List all available checks"
    echo -e "  --help         : Show this help message"
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --strict) STRICT_MODE="true"; shift ;;
            --html) HTML_REPORT="true"; shift ;;
            --no-html) HTML_REPORT="false"; shift ;;
            --graph) DEPENDENCY_GRAPH="true"; shift ;;
            --output) REPORTS_DIR="$2"; shift 2 ;;
            --verbose) VERBOSE="true"; shift ;;
            --list-checks)
                echo -e "${BOLD}Available checks:${NC}"
                for check in "${DEFAULT_CHECKS[@]}"; do
                    echo "  - $check"
                done
                exit 0
                ;;
            --help|-h) print_help ;;
            *) echo -e "${RED}Unknown option: $1${NC}"; print_help; exit 1 ;;
        esac
    done
}

finalize_html_report() {
    if [[ "$HTML_REPORT" == "true" ]]; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))

        cat >> "$REPORTS_DIR/pom-validation-report.html" <<HTML
        <div class="summary-section">
            <h2>Validation Summary</h2>
            <div class="progress-container">
                <div class="progress-bar" style="width:100%">100%</div>
            </div>
            <div class="summary-grid">
                <div class="summary-item pass">
                    <span class="summary-icon">${PASS_ICON}</span>
                    <span class="summary-count">${counts["pass"]}</span>
                    <span class="summary-label">Passed</span>
                </div>
                <div class="summary-item warn">
                    <span class="summary-icon">${WARN_ICON}</span>
                    <span class="summary-count">${counts["warn"]}</span>
                    <span class="summary-label">Warnings</span>
                </div>
                <div class="summary-item fail">
                    <span class="summary-icon">${FAIL_ICON}</span>
                    <span class="summary-count">${counts["fail"]}</span>
                    <span class="summary-label">Failures</span>
                </div>
                <div class="summary-item info">
                    <span class="summary-icon">${INFO_ICON}</span>
                    <span class="summary-count">${counts["info"]}</span>
                    <span class="summary-label">Info</span>
                </div>
            </div>
            <p class="execution-time">Validation completed in ${duration} seconds</p>
        </div>
        </body>
        </html>
HTML
    fi
}

main() {
    parse_arguments "$@"

    # Validate POM file exists and is valid XML
    if [[ ! -f "$POM_FILE" ]]; then
        echo -e "${RED}${BOLD}✗ Error: POM file not found: $POM_FILE${NC}"
        exit 1
    fi

    validate_xml
    init_output_dir
    print_header

    project_version="v$(get_tag_value version)"
    [[ -z "$project_version" ]] && project_version="v0.0.0"

    echo -e "${BOLD}${PURPLE}Project version: ${ORANGE}$project_version${NC}"
    echo -e "${BOLD}${PURPLE}Project stage: ${ORANGE}${MILESTONE_MAP[$project_version]:-"Unknown"}${NC}"
    echo -e "${BOLD}${PURPLE}Validation mode: ${ORANGE}$( [[ "$STRICT_MODE" == "true" ]] && echo "STRICT" || echo "NORMAL" )${NC}\n"

    # Calculate total checks
    # total_checks=${#DEFAULT_CHECKS[@]} # This was incorrect. It should be the count of recorded results.
    # We will set total_checks to ${#ALL_RESULTS[@]} after all checks are run.

    # Run checks
    for check in "${DEFAULT_CHECKS[@]}"; do
        func="${CHECK_FUNCS[$check]}"
        if declare -f "$func" > /dev/null; then
            $func
        else
            record_result "fail" "System" "Check $check" "Check function not found"
        fi
    done

    # Set total_checks to the actual number of results recorded
    total_checks=${#ALL_RESULTS[@]}

    # Print all results with calculated alignment
    print_aligned_results

    # Generate reports and outputs
    generate_dependency_graph

    # Show final progress with two lines gap
    echo -e "\n" # First newline before progress bar
    show_progress "$total_checks" "$total_checks" CHECK_STATUS_ARRAY[@]
    echo -e "\n\n" # Two newlines after progress bar

    # Finalize HTML report
    finalize_html_report

    # Summary
    echo -e "${BOLD}${CYAN}📊 Validation Summary:${NC}"
    local max_summary_label_len=0
    for label in "Passed" "Warnings" "Failures" "Info"; do
        # Calculate display length including the prefix icon (e.g., "✓ Passed")
        local display_label_str="✓ ${label}"
        local current_display_label_len=$(get_display_width "$display_label_str")
        if (( current_display_label_len > max_summary_label_len )); then
            max_summary_label_len="$current_display_label_len"
        fi
    done

    # Print summary with calculated alignment
    local summary_line_content

    # Passed line
    local display_label_str="✓ Passed"
    local current_display_label_len=$(get_display_width "$display_label_str")
    local pad_len=$((max_summary_label_len - current_display_label_len + 2)) # +2 for the 2-space gap
    local padded_label_str="Passed"
    for ((i=0; i<pad_len; i++)); do
        padded_label_str+=" "
    done
    summary_line_content="  ✓ ${padded_label_str}${PASS_ICON}  ${RESULT_ICON}  "
    printf -v final_summary_line "%s%3d" "$summary_line_content" "${counts["pass"]}"
    echo -e "${GREEN}${BOLD}${final_summary_line}${NC}"

    # Warnings line
    display_label_str="⚠ Warnings"
    current_display_label_len=$(get_display_width "$display_label_str")
    pad_len=$((max_summary_label_len - current_display_label_len + 2)) # +2 for the 2-space gap
    padded_label_str="Warnings"
    for ((i=0; i<pad_len; i++)); do
        padded_label_str+=" "
    done
    summary_line_content="  ⚠ ${padded_label_str}${WARN_ICON}  ${RESULT_ICON}  "
    printf -v final_summary_line "%s%3d" "$summary_line_content" "${counts["warn"]}"
    echo -e "${ORANGE}${BOLD}${final_summary_line}${NC}"

    # Failures line
    display_label_str="✗ Failures"
    current_display_label_len=$(get_display_width "$display_label_str")
    pad_len=$((max_summary_label_len - current_display_label_len + 2)) # +2 for the 2-space gap
    padded_label_str="Failures"
    for ((i=0; i<pad_len; i++)); do
        padded_label_str+=" "
    done
    summary_line_content="  ✗ ${padded_label_str}${FAIL_ICON}  ${RESULT_ICON}  "
    printf -v final_summary_line "%s%3d" "$summary_line_content" "${counts["fail"]}"
    echo -e "${RED}${BOLD}${final_summary_line}${NC}"

    # Info line
    display_label_str="ℹ Info"
    current_display_label_len=$(get_display_width "$display_label_str")
    pad_len=$((max_summary_label_len - current_display_label_len + 2)) # +2 for the 2-space gap
    padded_label_str="Info"
    for ((i=0; i<pad_len; i++)); do
        padded_label_str+=" "
    done
    summary_line_content="  ℹ ${padded_label_str}${INFO_ICON}  ${RESULT_ICON}  "
    printf -v final_summary_line "%s%3d" "$summary_line_content" "${counts["info"]}"
    echo -e "${BLUE}${BOLD}${final_summary_line}${NC}"


    end_time=$(date +%s)
    duration=$((end_time - start_time))
    echo -e "\n${BOLD}${PURPLE}⏱ Validation completed in ${duration} seconds${NC}"

    # Exit code based on strict mode
    fail_count=${counts["fail"]}
    warn_count=${counts["warn"]}
    if [[ "$STRICT_MODE" == "true" && $((fail_count + warn_count)) -gt 0 ]]; then
        exit 1
    elif [[ $fail_count -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
