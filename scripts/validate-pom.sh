#!/usr/bin/env bash
# validate-pom.sh — Milestone-aware Ultimate POM Validator with Progress Tracking

POM_FILE="pom.xml"

# === COLOR THEME ===
GREEN='\033[1;32m'
ORANGE='\033[38;5;214m'
RED='\033[1;31m'
WHITE='\033[1;37m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

# === ICONS ===
PASS_ICON="${GREEN}✓${NC}"
WARN_ICON="${ORANGE}⚠${NC}"
FAIL_ICON="${RED}✗${NC}"
SKIP_ICON="${WHITE}➤${NC}"
OPTIONAL_ICON="${CYAN}◇${NC}"

# === TRACKING ===
declare -A counts=( ["pass"]=0 ["warn"]=0 ["fail"]=0 ["skip"]=0 ["optional"]=0 )
completed_checks=0

# === MILESTONE MAP (version -> feature) ===
declare -A MILESTONE_MAP=(
  ["v0.0.0"]="initial"
  ["v0.1.0"]="simple-tests"
  ["v0.2.0"]="ci"
  ["v0.3.0"]="log4j"
  ["v0.4.0"]="exception-handling"
  ["v0.5.0"]="driver-manager"
  ["v0.6.0"]="pom"
  ["v0.7.0"]="wait-utils"
  ["v0.8.0"]="screenshot"
  ["v0.9.0"]="testng-listeners"
  ["v1.0.0"]="allure"
  ["v1.1.0"]="retry"
)

# === CHECK REGISTRY ===
declare -A CHECK_FUNCS=(
    [encoding]=check_encoding
    [selenium]=check_selenium_version
    [testng]=check_testng_version
    [java]=check_java_version
    [log4j]=check_log4j_version
    [allure]=check_allure_version
    [webdrivermanager]=check_webdrivermanager_version
    [surefire]=check_surefire_plugin_version
    [install]=check_install_plugin_version
    [testng_xml]=check_testng_xml_enabled
    [compiler]=check_compiler_plugin_version
    [clean]=check_clean_plugin_version
)

declare -a ALL_CHECKS=(
    "encoding"
    "selenium"
    "testng"
    "java"
    "log4j"
    "allure"
    "webdrivermanager"
    "surefire"
    "install"
    "testng_xml"
    "compiler"
    "clean"
)

# === HEADER ===
print_header() {
    echo -e "${PURPLE}"
    echo -e "╔════════════════════════════════════════════╗"
    echo -e "║  🚀  POM VALIDATOR  -  $(date +"%Y-%m-%d %H:%M")  ║"
    echo -e "╚════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# === PROGRESS BAR ===
show_progress() {
    local current=$1 total=$2 statuses=("${!3}")
    [[ $total -eq 0 ]] && return  # Avoid division by zero

    local bar=""
    for status in "${statuses[@]}"; do
        case "$status" in
          pass) bar+="🟩" ;;
          warn) bar+="🟧" ;;
          fail) bar+="🟥" ;;
          skip) bar+="⬛" ;;
          optional) bar+="🟦" ;;
          *) bar+="⬛" ;;
        esac
    done

    local percent=$((100 * current / total))
    echo -e "  [${bar}] ${percent}% (${current}/${total} checks)"
}

# === STATUS UPDATER ===
update_status() {
    local status=$1 message=$2
    local icon= color=

    case "$status" in
        pass) icon="$PASS_ICON"; color="$GREEN"; ((counts["pass"]++)) ;;
        warn) icon="$WARN_ICON"; color="$ORANGE"; ((counts["warn"]++)) ;;
        fail) icon="$FAIL_ICON"; color="$RED"; ((counts["fail"]++)) ;;
        skip) icon="$SKIP_ICON"; color="$WHITE"; ((counts["skip"]++)) ;;
        optional) icon="$OPTIONAL_ICON"; color="$CYAN"; ((counts["optional"]++)) ;;
    esac

    ((completed_checks++))
    CHECK_STATUS_ARRAY+=("$status")
    printf "  %b %b%-40s%b\n" "$icon" "$color" "$message" "$NC"
}

# === VERSION HELPERS ===
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
    # Compares two versions, returns true if $1 >= $2
    [ "$1" = "$2" ] && return 0
    [ "$(printf "%s\n%s" "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# Compare semantic version strings ignoring 'v' prefix
version_compare() {
    # usage: version_compare ver1 ver2
    # returns 0 if ver1 >= ver2 else 1
    local v1=${1#v}
    local v2=${2#v}
    version_ge "$v1" "$v2"
}

# === CHECK FUNCTIONS ===
check_encoding() {
    local val=$(get_tag_value "project.build.sourceEncoding")
    if [[ "$val" == "UTF-8" ]]; then
        update_status "pass" "Encoding: UTF-8"
    else
        update_status "warn" "Encoding: ${val:-Not specified} (recommend UTF-8)"
    fi
}

check_selenium_version() {
    local version=$(get_version_by_artifact_id "selenium-java")
    local resolved_version=$(resolve_property "$version")
    if [[ -n "$resolved_version" ]]; then
        if version_ge "$resolved_version" "4.0.0"; then
            update_status "pass" "Selenium: v$resolved_version"
        else
            update_status "fail" "Selenium: v$resolved_version (needs 4.0.0+)"
        fi
    else
        update_status "fail" "Selenium: Not found in dependencies"
    fi
}

check_testng_version() {
    local version=$(get_version_by_artifact_id "testng")
    local resolved_version=$(resolve_property "$version")
    if [[ -n "$resolved_version" ]]; then
        if version_ge "$resolved_version" "7.0.0"; then
            update_status "pass" "TestNG: v$resolved_version"
        else
            update_status "fail" "TestNG: v$resolved_version (needs 7.0.0+)"
        fi
    else
        update_status "fail" "TestNG: Not found in dependencies"
    fi
}

check_java_version() {
    local version=$(get_tag_value "java.version")
    if [[ -n "$version" ]]; then
        if version_ge "$version" "17"; then
            update_status "pass" "Java: v$version"
        else
            update_status "fail" "Java: v$version (needs 17+)"
        fi
    else
        update_status "warn" "Java: Version not specified"
    fi
}

check_log4j_version() {
    local version=$(get_version_by_artifact_id "log4j-core")
    local resolved_version=$(resolve_property "$version")
    if [[ -n "$resolved_version" ]]; then
        if version_ge "$resolved_version" "2.0.0"; then
            update_status "pass" "Log4j2: v$resolved_version"
        else
            update_status "fail" "Log4j2: v$resolved_version (needs 2.0.0+)"
        fi
    else
        update_status "optional" "Log4j2: Not found (optional)"
    fi
}

check_allure_version() {
    local version=$(get_version_by_artifact_id "allure-testng")
    local resolved_version=$(resolve_property "$version")
    if [[ -n "$resolved_version" ]]; then
        if version_ge "$resolved_version" "2.0.0"; then
            update_status "pass" "Allure: v$resolved_version"
        else
            update_status "fail" "Allure: v$resolved_version (needs 2.0.0+)"
        fi
    else
        update_status "optional" "Allure: Not found (optional)"
    fi
}

check_webdrivermanager_version() {
    local version=$(get_version_by_artifact_id "webdrivermanager")
    local resolved_version=$(resolve_property "$version")
    if [[ -n "$resolved_version" ]]; then
        if version_ge "$resolved_version" "5.0.0"; then
            update_status "pass" "WebDriverManager: v$resolved_version"
        else
            update_status "fail" "WebDriverManager: v$resolved_version (needs 5.0.0+)"
        fi
    else
        update_status "optional" "WebDriverManager: Not found (optional)"
    fi
}

check_surefire_plugin_version() {
    local version=$(get_version_by_artifact_id "maven-surefire-plugin")
    local resolved_version=$(resolve_property "$version")
    if [[ -n "$resolved_version" ]]; then
        update_status "pass" "Surefire Plugin: v$resolved_version"
    else
        update_status "warn" "Surefire Plugin: Not configured"
    fi
}

check_install_plugin_version() {
    # Assume default version is always acceptable
    update_status "pass" "Install Plugin: Default version acceptable"
}

check_testng_xml_enabled() {
    # Check for existence of testng.xml or TestNG suite configuration
    if grep -q "<suite-files>" "$POM_FILE" 2>/dev/null || [[ -f "testng.xml" ]]; then
        update_status "pass" "TestNG XML: Configured"
    else
        update_status "warn" "TestNG XML: Not configured (recommend for test suites)"
    fi
}

check_compiler_plugin_version() {
    local version=$(get_version_by_artifact_id "maven-compiler-plugin")
    local resolved_version=$(resolve_property "$version")
    if [[ -n "$resolved_version" ]]; then
        update_status "pass" "Compiler Plugin: v$resolved_version"
    else
        update_status "warn" "Compiler Plugin: Not found"
    fi
}

check_clean_plugin_version() {
    local version=$(get_version_by_artifact_id "maven-clean-plugin")
    local resolved_version=$(resolve_property "$version")
    if [[ -n "$resolved_version" ]]; then
        update_status "pass" "Clean Plugin: v$resolved_version"
    else
        update_status "warn" "Clean Plugin: Not found"
    fi
}

# === MILESTONE-BASED CHECK FILTERING ===
filter_checks_by_version() {
    local ver=$1
    FILTERED_CHECKS=()

    # Required up to milestone version
    # Use version_compare to filter checks

    # Encoding always required
    FILTERED_CHECKS+=("encoding")
    FILTERED_CHECKS+=("selenium")
    FILTERED_CHECKS+=("testng")
    FILTERED_CHECKS+=("java")

    # Log4j from v0.3.0+
    if version_compare "$ver" "v0.3.0"; then
        FILTERED_CHECKS+=("log4j")
    else
        SKIPPED_CHECKS+=("log4j: skipped (Log4j2 integration milestone >= v0.3.0)")
    fi

    # Allure from v1.0.0+
    if version_compare "$ver" "v1.0.0"; then
        FILTERED_CHECKS+=("allure")
    else
        SKIPPED_CHECKS+=("allure: skipped (Allure Integration milestone >= v1.0.0)")
    fi

    # WebDriverManager from v0.5.0+
    if version_compare "$ver" "v0.5.0"; then
        FILTERED_CHECKS+=("webdrivermanager")
    else
        SKIPPED_CHECKS+=("webdrivermanager: skipped (Driver Management milestone >= v0.5.0)")
    fi

    # Surefire always checked (warn if missing)
    FILTERED_CHECKS+=("surefire")
    FILTERED_CHECKS+=("install")

    # TestNG XML from v0.9.0+
    if version_compare "$ver" "v0.9.0"; then
        FILTERED_CHECKS+=("testng_xml")
    else
        SKIPPED_CHECKS+=("testng_xml: skipped (TestNG Listeners milestone >= v0.9.0)")
    fi

    # Compiler plugin always checked
    FILTERED_CHECKS+=("compiler")
    FILTERED_CHECKS+=("clean")
}

# === MAIN ===
main() {
    print_header

    if [[ ! -f "$POM_FILE" ]]; then
        echo -e "${RED}Error:${NC} $POM_FILE not found!"
        exit 1
    fi

    # Extract current version (fallback to v0.0.0 if missing)
    raw_version=$(get_tag_value "version")
    if [[ -z "$raw_version" ]]; then
        raw_version="0.0.0"
    fi
    # Normalize to vX.Y.Z format for matching
    project_version="v${raw_version#v}"

    echo -e "🔍 Validating $POM_FILE"
    echo ""

    # Initialize skipped array & completed checks array
    SKIPPED_CHECKS=()
    CHECK_STATUS_ARRAY=()

    # Determine checks based on milestone version
    filter_checks_by_version "$project_version"

    total_checks=${#FILTERED_CHECKS[@]}

    # Run checks
    for check in "${FILTERED_CHECKS[@]}"; do
        func=${CHECK_FUNCS[$check]}
        if [[ -n "$func" ]]; then
            $func
        else
            update_status "skip" "$check: No function defined"
        fi
    done

    # Print skipped checks (due to milestone)
    if (( ${#SKIPPED_CHECKS[@]} > 0 )); then
        echo ""
        for skip_msg in "${SKIPPED_CHECKS[@]}"; do
            update_status "skip" "$skip_msg"
        done
    fi

    # Show final progress bar
    echo ""
    show_progress $completed_checks $((total_checks + ${#SKIPPED_CHECKS[@]})) CHECK_STATUS_ARRAY[@]
    echo ""

    # Validation summary
    echo -e "📊 Validation Summary:"
    echo -e "  ${PASS_ICON} Passed:     ${counts["pass"]}/${completed_checks}"
    echo -e "  ${WARN_ICON} Warnings:   ${counts["warn"]}"
    echo -e "  ${OPTIONAL_ICON} Optional:   ${counts["optional"]}"
    echo -e "  ${SKIP_ICON} Skipped:    ${counts["skip"]}"
    echo -e "  ${FAIL_ICON} Failures:   ${counts["fail"]}"
    echo ""

    if (( counts["fail"] > 0 )); then
        echo -e "${RED}✗ Validation failed with ${counts["fail"]} failure(s).${NC}"
        exit 2
    elif (( counts["warn"] > 0 )); then
        echo -e "${ORANGE}⚠ Validation passed with ${counts["warn"]} warning(s) and ${counts["skip"]} skipped.${NC}"
        exit 0
    else
        echo -e "${GREEN}✓ Validation passed with no warnings.${NC}"
        exit 0
    fi
}

main "$@"
