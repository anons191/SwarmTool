#!/usr/bin/env bash
# core.sh -- Shared constants, utilities, logging, color output
# Sourced by swarmtool main entry point. Do not execute directly.

# Prevent double-sourcing
[[ -n "${_SWARMTOOL_CORE_LOADED:-}" ]] && return 0
_SWARMTOOL_CORE_LOADED=1

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Disable colors if stdout is not a terminal
if [[ ! -t 1 ]]; then
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# ── Globals ─────────────────────────────────────────────────────────────────
SWARMTOOL_VERSION="0.1.0"
SWARMTOOL_STATE_DIR=".swarmtool"
ORIGINAL_PWD="$(pwd)"

# ── Logging ─────────────────────────────────────────────────────────────────

# Log to run log file and stderr
# Usage: log <run_id> <component> <message>
log() {
    local run_id="$1" component="$2" message="$3"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local entry="[$timestamp] [$component] $message"

    # Append to run log if run directory exists
    local run_log="${SWARMTOOL_STATE_DIR}/runs/${run_id}/run.log"
    if [[ -n "$run_id" && -d "${SWARMTOOL_STATE_DIR}/runs/${run_id}" ]]; then
        echo "$entry" >> "$run_log"
    fi

    # Print to stderr for live feedback
    printf "${DIM}%s${NC} ${CYAN}[%s]${NC} %s\n" "$timestamp" "$component" "$message" >&2
}

# Log an error (always printed, no run_id required)
log_error() {
    printf "${RED}ERROR:${NC} %s\n" "$1" >&2
}

# Log a warning
log_warn() {
    printf "${YELLOW}WARNING:${NC} %s\n" "$1" >&2
}

# Log an info message
log_info() {
    printf "${BLUE}INFO:${NC} %s\n" "$1" >&2
}

# Log a success message
log_success() {
    printf "${GREEN}OK:${NC} %s\n" "$1" >&2
}

# Fatal error -- print message and exit
die() {
    log_error "$1"
    exit "${2:-1}"
}

# ── Prerequisites ───────────────────────────────────────────────────────────

check_prerequisites() {
    local missing=0

    if ! command -v git >/dev/null 2>&1; then
        log_error "git is required but not found"
        missing=1
    fi

    if ! command -v claude >/dev/null 2>&1; then
        log_error "claude CLI is required but not found (https://docs.anthropic.com/en/docs/claude-code)"
        missing=1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required but not found (brew install jq)"
        missing=1
    fi

    [[ $missing -eq 1 ]] && die "Missing prerequisites. Install the above and try again."

    # Verify we're in a git repository
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "swarmtool must be run inside a git repository"
    fi
}

# Warn if working tree is dirty
check_clean_worktree() {
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        log_warn "Working tree has uncommitted changes."
        echo "It is recommended to commit or stash changes before running swarmtool."
        printf "Continue anyway? [y/N] "
        read -r reply
        [[ "$reply" =~ ^[Yy]$ ]] || exit 0
    fi
}

# ── Utility Functions ───────────────────────────────────────────────────────

# Generate a short unique ID (first 8 chars of a UUID)
generate_id() {
    uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | cut -c1-8 || \
        date +%s%N | shasum | cut -c1-8
}

# Generate a full UUID
generate_uuid() {
    uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || \
        cat /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | head -c 32 | \
        sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/'
}

# Get current git branch
get_current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Get current commit SHA
get_current_commit() {
    git rev-parse HEAD 2>/dev/null
}

# Ensure a directory exists
ensure_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || mkdir -p "$dir"
}

# Print a horizontal rule
hr() {
    local char="${1:--}"
    printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' "$char"
}

# Print a header
print_header() {
    local text="$1"
    echo ""
    printf "${BOLD}%s${NC}\n" "$text"
    hr "─"
}

# Print a section
print_section() {
    local text="$1"
    printf "\n${BOLD}${CYAN}%s${NC}\n" "$text"
}

# Count files matching a glob (returns 0 if none)
count_files() {
    local pattern="$1"
    local count=0
    for f in $pattern; do
        [[ -e "$f" ]] && count=$((count + 1))
    done
    echo "$count"
}
