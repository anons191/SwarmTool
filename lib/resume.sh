#!/usr/bin/env bash
# resume.sh -- Detect interrupted runs and resume from last state
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_RESUME_LOADED:-}" ]] && return 0
_SWARMTOOL_RESUME_LOADED=1

# ── Resume Logic ────────────────────────────────────────────────────────────

# Resume an interrupted run from its persisted state
# Usage: resume_run <run_id>
resume_run() {
    local run_id="$1"
    local run_dir="${SWARMTOOL_STATE_DIR}/runs/${run_id}"

    if [[ ! -d "$run_dir" ]]; then
        # Try partial match
        local matches=()
        for d in "${SWARMTOOL_STATE_DIR}/runs/${run_id}"*/; do
            [[ -d "$d" ]] && matches+=("$d")
        done

        if [[ ${#matches[@]} -eq 1 ]]; then
            run_dir="${matches[0]%/}"
            run_id=$(basename "$run_dir")
            log_info "Matched run: ${run_id}"
        elif [[ ${#matches[@]} -gt 1 ]]; then
            log_error "Ambiguous run ID '${run_id}'. Multiple matches:"
            for m in "${matches[@]}"; do
                echo "  $(basename "${m%/}")"
            done
            return 1
        else
            log_error "Run not found: ${run_id}"
            echo "Available runs:"
            list_runs
            return 1
        fi
    fi

    local state
    state=$(get_run_state "$run_dir")
    local goal
    goal=$(get_run_meta "$run_dir" "GOAL")

    print_header "Resuming Run: ${run_id}"
    echo "Goal:  ${goal}"
    echo "State: ${state}"
    echo ""

    # Set globals for signal handler
    CURRENT_RUN_ID="$run_id"
    CURRENT_RUN_DIR="$run_dir"

    case "$state" in
        initialized)
            log "$run_id" "RESUME" "Resuming from initialized state"
            # Need to run planning
            set_run_state "$run_dir" "planning"

            if type run_planning_phase &>/dev/null; then
                run_planning_phase "$run_id" "$run_dir" "$goal"
            else
                die "Planner module not available."
            fi

            _resume_from_planning "$run_id" "$run_dir" "$goal"
            ;;

        planning)
            log "$run_id" "RESUME" "Resuming from planning state"

            # Check if plan was partially completed
            local task_count
            task_count=$(count_tasks "$run_dir")

            if [[ $task_count -gt 0 ]]; then
                log_info "Found ${task_count} existing tasks. Skipping to review."
            else
                if type run_planning_phase &>/dev/null; then
                    run_planning_phase "$run_id" "$run_dir" "$goal"
                else
                    die "Planner module not available."
                fi
            fi

            _resume_from_planning "$run_id" "$run_dir" "$goal"
            ;;

        approved)
            log "$run_id" "RESUME" "Resuming from approved state"
            _resume_from_execution "$run_id" "$run_dir"
            ;;

        executing)
            log "$run_id" "RESUME" "Resuming from executing state"

            # Reset any "running" tasks back to "pending" (their workers died)
            local reset_count=0
            for status_file in "${run_dir}/tasks/"*.status; do
                [[ -f "$status_file" ]] || continue
                if [[ "$(cat "$status_file")" == "running" ]]; then
                    echo "pending" > "$status_file"
                    local tid
                    tid=$(basename "$status_file" .status)
                    teardown_worktree "$run_dir" "$tid"
                    reset_count=$((reset_count + 1))
                fi
            done

            if [[ $reset_count -gt 0 ]]; then
                log "$run_id" "RESUME" "Reset ${reset_count} interrupted tasks to pending"
                log_info "Reset ${reset_count} interrupted tasks to pending"
            fi

            display_progress "$run_dir"
            echo ""
            _resume_from_execution "$run_id" "$run_dir"
            ;;

        judging)
            log "$run_id" "RESUME" "Resuming from judging state"
            _resume_from_judging "$run_id" "$run_dir"
            ;;

        merging)
            log "$run_id" "RESUME" "Resuming from merging state"
            _resume_from_merging "$run_id" "$run_dir"
            ;;

        complete)
            printf "${GREEN}Run ${run_id} is already complete.${NC}\n"
            display_progress "$run_dir"
            return 0
            ;;

        failed)
            log_warn "Run ${run_id} previously failed."
            echo ""
            echo "Last log entries:"
            tail -5 "${run_dir}/run.log" 2>/dev/null
            echo ""
            printf "Retry from the failed state? [y/N] "
            read -r retry
            if [[ "$retry" =~ ^[Yy]$ ]]; then
                # Determine what state to retry from
                local last_good_state
                last_good_state=$(_detect_last_good_state "$run_dir")
                log "$run_id" "RESUME" "Retrying from ${last_good_state}"
                force_run_state "$run_dir" "$last_good_state"
                resume_run "$run_id"
            fi
            return 1
            ;;

        *)
            die "Unknown state: ${state}"
            ;;
    esac
}

# ── Resume Helpers ──────────────────────────────────────────────────────────

_resume_from_planning() {
    local run_id="$1" run_dir="$2" goal="$3"

    # Interactive review
    if type run_review_phase &>/dev/null; then
        run_review_phase "$run_id" "$run_dir"
    else
        display_all_tasks "$run_dir"
        printf "Approve and execute? [y/N] "
        read -r reply
        [[ "$reply" =~ ^[Yy]$ ]] || exit 0
    fi

    set_run_state "$run_dir" "approved"
    _resume_from_execution "$run_id" "$run_dir"
}

_resume_from_execution() {
    local run_id="$1" run_dir="$2"

    # Check for pending tasks
    local pending
    pending=$(count_tasks "$run_dir" "pending")
    if [[ $pending -eq 0 ]]; then
        log_info "All tasks already completed. Moving to judging."
    else
        set_run_state "$run_dir" "executing" 2>/dev/null || force_run_state "$run_dir" "executing"

        if type run_execution_phase &>/dev/null; then
            run_execution_phase "$run_id" "$run_dir"
        else
            die "Execution module not available."
        fi
    fi

    _resume_from_judging "$run_id" "$run_dir"
}

_resume_from_judging() {
    local run_id="$1" run_dir="$2"

    set_run_state "$run_dir" "judging" 2>/dev/null || force_run_state "$run_dir" "judging"

    if type run_judging_phase &>/dev/null; then
        run_judging_phase "$run_id" "$run_dir"
    else
        log_warn "Judge module not available. Auto-passing all tasks."
        for task_id in $(list_tasks_by_status "$run_dir" "done"); do
            if [[ ! -f "${run_dir}/tasks/${task_id}.judge" ]]; then
                echo "VERDICT=pass" > "${run_dir}/tasks/${task_id}.judge"
            fi
        done
    fi

    _resume_from_merging "$run_id" "$run_dir"
}

_resume_from_merging() {
    local run_id="$1" run_dir="$2"

    set_run_state "$run_dir" "merging" 2>/dev/null || force_run_state "$run_dir" "merging"

    if type run_merge_phase &>/dev/null; then
        run_merge_phase "$run_id" "$run_dir"
    else
        die "Merge module not available."
    fi

    set_run_state "$run_dir" "complete" 2>/dev/null || force_run_state "$run_dir" "complete"
    log "$run_id" "MAIN" "Run complete (resumed)"

    echo ""
    print_header "Run Complete"
    display_progress "$run_dir"
    echo ""
    echo "Run ID: ${run_id}"
    echo "Logs:   ${run_dir}/run.log"

    cleanup_run "$run_dir"
}

# Detect the last good state before failure
_detect_last_good_state() {
    local run_dir="$1"

    # Check what's been completed
    local task_count
    task_count=$(count_tasks "$run_dir")
    local done_count
    done_count=$(count_tasks "$run_dir" "done")
    local has_judges=false
    for f in "${run_dir}/tasks/"*.judge; do
        [[ -f "$f" ]] && has_judges=true && break
    done

    if [[ "$has_judges" == "true" ]]; then
        echo "merging"
    elif [[ $done_count -gt 0 ]]; then
        echo "judging"
    elif [[ $task_count -gt 0 ]]; then
        echo "approved"
    else
        echo "initialized"
    fi
}
