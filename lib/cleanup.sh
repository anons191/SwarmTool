#!/usr/bin/env bash
# cleanup.sh -- Signal handling, graceful shutdown, worktree cleanup
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_CLEANUP_LOADED:-}" ]] && return 0
_SWARMTOOL_CLEANUP_LOADED=1

# ── Globals ─────────────────────────────────────────────────────────────────
# These are populated by the execution loop
WORKER_PIDS=()           # Array of "pid:task_id" strings
CURRENT_RUN_ID=""
CURRENT_RUN_DIR=""
SHUTDOWN_REQUESTED=false

# ── Signal Handlers ─────────────────────────────────────────────────────────

setup_signal_handlers() {
    trap 'handle_shutdown SIGINT' INT
    trap 'handle_shutdown SIGTERM' TERM
}

handle_shutdown() {
    local signal="$1"

    if [[ "$SHUTDOWN_REQUESTED" == "true" ]]; then
        # Second signal = force kill
        printf "\n${RED}Force shutdown. Killing all workers...${NC}\n" >&2
        kill_all_workers 9
        cleanup_and_exit 1
        return
    fi

    SHUTDOWN_REQUESTED=true
    printf "\n${YELLOW}Shutdown requested (%s). Gracefully stopping workers...${NC}\n" "$signal" >&2
    echo "Press Ctrl+C again to force-kill." >&2

    # Send SIGTERM to all active workers
    kill_all_workers 15

    # Wait up to 30 seconds for workers to finish
    local wait_count=0
    while [[ $wait_count -lt 30 ]]; do
        local any_alive=false
        for entry in "${WORKER_PIDS[@]}"; do
            local pid="${entry%%:*}"
            if kill -0 "$pid" 2>/dev/null; then
                any_alive=true
                break
            fi
        done
        [[ "$any_alive" != "true" ]] && break
        sleep 1
        wait_count=$((wait_count + 1))
    done

    # Force kill any remaining
    kill_all_workers 9

    # Mark running tasks as pending (for resume)
    if [[ -n "$CURRENT_RUN_DIR" && -d "$CURRENT_RUN_DIR" ]]; then
        for status_file in "${CURRENT_RUN_DIR}/tasks/"*.status; do
            [[ -f "$status_file" ]] || continue
            if [[ "$(cat "$status_file")" == "running" ]]; then
                echo "pending" > "$status_file"
            fi
        done

        log "$CURRENT_RUN_ID" "SHUTDOWN" "Run interrupted. Resume with: swarmtool --resume $CURRENT_RUN_ID"
        printf "\n${YELLOW}Run interrupted. Resume with:${NC}\n" >&2
        printf "  swarmtool --resume %s\n\n" "$CURRENT_RUN_ID" >&2
    fi

    cleanup_and_exit 0
}

# Kill all tracked worker processes with the given signal
kill_all_workers() {
    local sig="${1:-15}"
    for entry in "${WORKER_PIDS[@]}"; do
        local pid="${entry%%:*}"
        kill "-${sig}" "$pid" 2>/dev/null
    done
}

# Final cleanup before exit
cleanup_and_exit() {
    local exit_code="${1:-0}"

    # Remove PID files
    if [[ -n "$CURRENT_RUN_DIR" && -d "${CURRENT_RUN_DIR}/pids" ]]; then
        rm -f "${CURRENT_RUN_DIR}/pids/"*.pid 2>/dev/null
    fi

    exit "$exit_code"
}

# ── Worktree Cleanup ───────────────────────────────────────────────────────

# Tear down a single worktree for a task
# Usage: teardown_worktree <run_dir> <task_id>
teardown_worktree() {
    local run_dir="$1" task_id="$2"
    local worktree_file="${run_dir}/tasks/${task_id}.worktree"

    if [[ -f "$worktree_file" ]]; then
        local worktree_path
        worktree_path=$(cat "$worktree_file")

        if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
            git worktree remove --force "$worktree_path" 2>/dev/null || true
        fi
    fi
}

# Tear down all worktrees for a run
# Usage: teardown_all_worktrees <run_dir>
teardown_all_worktrees() {
    local run_dir="$1"

    for worktree_file in "${run_dir}/tasks/"*.worktree; do
        [[ -f "$worktree_file" ]] || continue
        local task_id
        task_id=$(basename "$worktree_file" .worktree)
        teardown_worktree "$run_dir" "$task_id"
    done

    # Prune any stale worktree references
    git worktree prune 2>/dev/null || true
}

# Clean up task branches after successful merge
# Usage: cleanup_task_branches <run_dir>
cleanup_task_branches() {
    local run_dir="$1"

    for spec_file in "${run_dir}/tasks/"*.spec; do
        [[ -f "$spec_file" ]] || continue
        local branch
        branch=$(taskspec_get "$spec_file" "TASK_BRANCH")
        if [[ -n "$branch" ]]; then
            git branch -D "$branch" 2>/dev/null || true
        fi
    done
}

# Full cleanup for a completed run
# Usage: cleanup_run <run_dir> [keep_worktrees]
cleanup_run() {
    local run_dir="$1"
    local keep_worktrees="${2:-false}"

    if [[ "$keep_worktrees" != "true" ]]; then
        teardown_all_worktrees "$run_dir"
    fi

    # Remove PID files
    rm -f "${run_dir}/pids/"*.pid 2>/dev/null
}
