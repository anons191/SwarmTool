#!/usr/bin/env bash
# config.sh -- Configuration loading with precedence:
#   defaults.conf <- .swarmtool/config <- environment variables <- CLI flags
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_CONFIG_LOADED:-}" ]] && return 0
_SWARMTOOL_CONFIG_LOADED=1

# ── Default Values ──────────────────────────────────────────────────────────
# These are overridden by config files, env vars, and CLI flags (in that order).

# Models
: "${SWARMTOOL_PLANNER_MODEL:=opus}"
: "${SWARMTOOL_WORKER_MODEL:=sonnet}"
: "${SWARMTOOL_JUDGE_MODEL:=sonnet}"
: "${SWARMTOOL_MERGE_MODEL:=sonnet}"

# Budget (USD)
: "${SWARMTOOL_PLANNER_BUDGET:=2.00}"
: "${SWARMTOOL_WORKER_BUDGET:=1.00}"
: "${SWARMTOOL_JUDGE_BUDGET:=0.50}"
: "${SWARMTOOL_MERGE_BUDGET:=0.50}"
: "${SWARMTOOL_TOTAL_BUDGET:=20.00}"

# Concurrency
: "${SWARMTOOL_MAX_WORKERS:=0}"          # 0 = auto-detect
: "${SWARMTOOL_API_CONCURRENCY:=5}"      # Max concurrent API calls
: "${SWARMTOOL_HARD_MAX_WORKERS:=10}"    # Absolute ceiling

# Worker settings
: "${SWARMTOOL_WORKER_MAX_RETRIES:=2}"
: "${SWARMTOOL_RETRY_DELAY:=10}"         # seconds, doubles each retry

# Merge settings
: "${SWARMTOOL_AUTO_MERGE:=true}"
: "${SWARMTOOL_FINAL_VALIDATION:=true}"

# Paths
: "${SWARMTOOL_STATE_DIR:=.swarmtool}"

# ── Config Loading ──────────────────────────────────────────────────────────

# Load a config file (key=value format, lines starting with # are comments)
_load_config_file() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 0

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        # Parse key=value
        key="${line%%=*}"
        value="${line#*=}"

        # Only set if it's a recognized SWARMTOOL_ variable
        case "$key" in
            SWARMTOOL_*)
                eval "export ${key}=\"${value}\""
                ;;
        esac
    done < "$config_file"
}

# Load configuration with precedence
load_config() {
    local swarmtool_dir="$1"  # Path to the swarmtool installation directory

    # 1. Load built-in defaults (from swarmtool installation)
    if [[ -n "$swarmtool_dir" && -f "${swarmtool_dir}/defaults.conf" ]]; then
        _load_config_file "${swarmtool_dir}/defaults.conf"
    fi

    # 2. Load project-level config
    if [[ -f "${SWARMTOOL_STATE_DIR}/config" ]]; then
        _load_config_file "${SWARMTOOL_STATE_DIR}/config"
    fi

    # 3. Environment variables already take precedence (set via : "${VAR:=default}" above)
    # 4. CLI flags are applied after this function returns (in the main script)
}

# Apply CLI flag overrides
apply_cli_overrides() {
    local flag="$1" value="$2"

    case "$flag" in
        --max-workers)
            SWARMTOOL_MAX_WORKERS="$value"
            ;;
        --planner-model)
            SWARMTOOL_PLANNER_MODEL="$value"
            ;;
        --worker-model)
            SWARMTOOL_WORKER_MODEL="$value"
            ;;
        --judge-model)
            SWARMTOOL_JUDGE_MODEL="$value"
            ;;
        --budget)
            SWARMTOOL_TOTAL_BUDGET="$value"
            ;;
        --state-dir)
            SWARMTOOL_STATE_DIR="$value"
            ;;
    esac
}

# Print current configuration (for debugging)
dump_config() {
    print_section "Configuration"
    echo "  Planner model:    $SWARMTOOL_PLANNER_MODEL"
    echo "  Worker model:     $SWARMTOOL_WORKER_MODEL"
    echo "  Judge model:      $SWARMTOOL_JUDGE_MODEL"
    echo "  Merge model:      $SWARMTOOL_MERGE_MODEL"
    echo "  Planner budget:   \$$SWARMTOOL_PLANNER_BUDGET"
    echo "  Worker budget:    \$$SWARMTOOL_WORKER_BUDGET"
    echo "  Judge budget:     \$$SWARMTOOL_JUDGE_BUDGET"
    echo "  Total budget:     \$$SWARMTOOL_TOTAL_BUDGET"
    echo "  Max workers:      ${SWARMTOOL_MAX_WORKERS:-auto}"
    echo "  API concurrency:  $SWARMTOOL_API_CONCURRENCY"
    echo "  Hard max workers: $SWARMTOOL_HARD_MAX_WORKERS"
    echo "  Worker retries:   $SWARMTOOL_WORKER_MAX_RETRIES"
    echo "  State dir:        $SWARMTOOL_STATE_DIR"
}
