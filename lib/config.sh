#!/usr/bin/env bash
# config.sh -- Configuration loading with precedence:
#   defaults.conf <- .swarmtool/config <- environment variables <- CLI flags
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_CONFIG_LOADED:-}" ]] && return 0
_SWARMTOOL_CONFIG_LOADED=1

# ── Default Values ──────────────────────────────────────────────────────────
# These are overridden by config files, env vars, and CLI flags (in that order).

# Provider:Model specs (format: provider:model or just model for Claude)
# Examples: "claude:opus", "openai:gpt-4o", "ollama:qwen2", "opus"
: "${SWARMTOOL_PLANNER:=claude:opus}"
: "${SWARMTOOL_WORKER:=claude:sonnet}"
: "${SWARMTOOL_JUDGE:=claude:opus}"
: "${SWARMTOOL_FIXER:=claude:opus}"
: "${SWARMTOOL_MERGER:=claude:opus}"

# Legacy model-only variables (for backwards compatibility)
# These are derived from the new format or can override it
: "${SWARMTOOL_PLANNER_MODEL:=}"
: "${SWARMTOOL_WORKER_MODEL:=}"
: "${SWARMTOOL_JUDGE_MODEL:=}"
: "${SWARMTOOL_MERGE_MODEL:=}"

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
        # New provider:model flags
        --planner)
            SWARMTOOL_PLANNER="$value"
            ;;
        --worker)
            SWARMTOOL_WORKER="$value"
            ;;
        --judge)
            SWARMTOOL_JUDGE="$value"
            ;;
        --fixer)
            SWARMTOOL_FIXER="$value"
            ;;
        --merger)
            SWARMTOOL_MERGER="$value"
            ;;
        # Legacy model-only flags (for backwards compatibility)
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

# ── Provider Resolution ────────────────────────────────────────────────────

# Resolve provider spec for a role, handling backwards compatibility
# Usage: resolve_provider_spec <role>
# Returns: provider:model string
resolve_provider_spec() {
    local role="$1"
    local spec=""
    local legacy_model=""

    case "$role" in
        planner)
            spec="${SWARMTOOL_PLANNER:-}"
            legacy_model="${SWARMTOOL_PLANNER_MODEL:-}"
            ;;
        worker)
            spec="${SWARMTOOL_WORKER:-}"
            legacy_model="${SWARMTOOL_WORKER_MODEL:-}"
            ;;
        judge)
            spec="${SWARMTOOL_JUDGE:-}"
            legacy_model="${SWARMTOOL_JUDGE_MODEL:-}"
            ;;
        fixer)
            spec="${SWARMTOOL_FIXER:-}"
            legacy_model="${SWARMTOOL_MERGE_MODEL:-}"  # Fixer uses merge model in legacy
            ;;
        merger)
            spec="${SWARMTOOL_MERGER:-}"
            legacy_model="${SWARMTOOL_MERGE_MODEL:-}"
            ;;
        *)
            echo "claude:sonnet"
            return
            ;;
    esac

    # If legacy model is set, it overrides for Claude provider
    if [[ -n "$legacy_model" ]]; then
        echo "claude:${legacy_model}"
        return
    fi

    # Return the spec (default to claude:sonnet if empty)
    echo "${spec:-claude:sonnet}"
}

# Print current configuration (for debugging)
dump_config() {
    print_section "Configuration"
    echo "  Planner:          $(resolve_provider_spec planner)"
    echo "  Worker:           $(resolve_provider_spec worker)"
    echo "  Judge:            $(resolve_provider_spec judge)"
    echo "  Fixer:            $(resolve_provider_spec fixer)"
    echo "  Merger:           $(resolve_provider_spec merger)"
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
