#!/usr/bin/env bash
# state.sh -- State machine management for swarmtool runs
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_STATE_LOADED:-}" ]] && return 0
_SWARMTOOL_STATE_LOADED=1

# ── Valid States ────────────────────────────────────────────────────────────
# Run states:
#   initialized -> [interviewing] -> planning -> approved -> executing -> judging -> merging -> complete
#   Any state can transition to -> failed
#   Interview phase is optional (initialized can go directly to planning)

VALID_RUN_STATES="initialized interviewing planning approved executing judging merging complete failed"

# Valid state transitions (from:to)
VALID_TRANSITIONS="
initialized:interviewing
initialized:planning
interviewing:planning
interviewing:failed
planning:approved
planning:failed
approved:executing
executing:judging
executing:failed
judging:merging
judging:failed
merging:complete
merging:failed
"

# ── Run State Functions ─────────────────────────────────────────────────────

# Get the current state of a run
# Usage: get_run_state <run_dir>
get_run_state() {
    local run_dir="$1"
    if [[ -f "${run_dir}/run.state" ]]; then
        cat "${run_dir}/run.state"
    else
        echo "unknown"
    fi
}

# Set the state of a run (with transition validation)
# Usage: set_run_state <run_dir> <new_state>
set_run_state() {
    local run_dir="$1"
    local new_state="$2"
    local current_state

    current_state=$(get_run_state "$run_dir")

    # Allow setting initial state on a new run
    if [[ "$current_state" == "unknown" && "$new_state" == "initialized" ]]; then
        echo "$new_state" > "${run_dir}/run.state"
        return 0
    fi

    # Validate the transition
    local transition="${current_state}:${new_state}"
    if ! echo "$VALID_TRANSITIONS" | grep -q "^${transition}$"; then
        log_error "Invalid state transition: ${current_state} -> ${new_state}"
        return 1
    fi

    echo "$new_state" > "${run_dir}/run.state"

    # Log the transition
    local run_id
    run_id=$(basename "$run_dir")
    log "$run_id" "STATE" "${current_state} -> ${new_state}"
    return 0
}

# Force-set state (bypass validation -- use for recovery only)
# Usage: force_run_state <run_dir> <new_state>
force_run_state() {
    local run_dir="$1"
    local new_state="$2"

    # Validate the state is a known state
    if ! echo "$VALID_RUN_STATES" | tr ' ' '\n' | grep -q "^${new_state}$"; then
        log_error "Unknown state: ${new_state}"
        return 1
    fi

    local old_state
    old_state=$(get_run_state "$run_dir")
    echo "$new_state" > "${run_dir}/run.state"

    local run_id
    run_id=$(basename "$run_dir")
    log "$run_id" "STATE" "FORCED: ${old_state} -> ${new_state}"
    return 0
}

# ── Run Directory Management ───────────────────────────────────────────────

# Initialize a new run directory
# Usage: init_run_dir <run_id> <goal>
# Returns: path to the run directory
init_run_dir() {
    local run_id="$1"
    local goal="$2"
    local run_dir="${SWARMTOOL_STATE_DIR}/runs/${run_id}"

    # Create directory structure
    mkdir -p "${run_dir}/tasks"
    mkdir -p "${run_dir}/merge"
    mkdir -p "${run_dir}/pids"

    # Write metadata
    local base_branch base_commit
    base_branch=$(get_current_branch)
    base_commit=$(get_current_commit)

    cat > "${run_dir}/run.meta" <<EOF
RUN_ID=${run_id}
GOAL=${goal}
BASE_BRANCH=${base_branch}
BASE_COMMIT=${base_commit}
START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SWARMTOOL_VERSION=${SWARMTOOL_VERSION}
MAX_WORKERS=${SWARMTOOL_MAX_WORKERS}
EOF

    # Initialize state
    echo "initialized" > "${run_dir}/run.state"

    # Initialize empty log
    touch "${run_dir}/run.log"

    echo "$run_dir"
}

# Get a metadata value from run.meta
# Usage: get_run_meta <run_dir> <key>
get_run_meta() {
    local run_dir="$1"
    local key="$2"
    grep "^${key}=" "${run_dir}/run.meta" 2>/dev/null | head -1 | cut -d'=' -f2-
}

# ── Run Listing ─────────────────────────────────────────────────────────────

# List all runs with their status
list_runs() {
    local runs_dir="${SWARMTOOL_STATE_DIR}/runs"
    if [[ ! -d "$runs_dir" ]]; then
        echo "No runs found."
        return 0
    fi

    printf "${BOLD}%-10s  %-12s  %s${NC}\n" "RUN ID" "STATE" "GOAL"
    hr "─"

    for run_dir in "${runs_dir}"/*/; do
        [[ -d "$run_dir" ]] || continue
        local run_id state goal
        run_id=$(basename "$run_dir")
        state=$(get_run_state "$run_dir")
        goal=$(get_run_meta "$run_dir" "GOAL" | head -c 60)

        # Color the state
        local state_color="$NC"
        case "$state" in
            complete)   state_color="$GREEN" ;;
            failed)     state_color="$RED" ;;
            executing)  state_color="$BLUE" ;;
            *)          state_color="$YELLOW" ;;
        esac

        printf "%-10s  ${state_color}%-12s${NC}  %s\n" "$run_id" "$state" "$goal"
    done
}
