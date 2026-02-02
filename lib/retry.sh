#!/usr/bin/env bash
# retry.sh -- Retry failed tasks by having planner improve task specs
# Following Rule 2: Workers stay ignorant (they don't see other workers' failures)
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_RETRY_LOADED:-}" ]] && return 0
_SWARMTOOL_RETRY_LOADED=1

# ── Retry Phase ─────────────────────────────────────────────────────────────

# Run the retry phase: re-execute failed tasks with improved specs
# Usage: run_retry_phase <run_id> <run_dir>
run_retry_phase() {
    local run_id="$1"
    local run_dir="$2"
    local max_rounds="${SWARMTOOL_MAX_RETRY_ROUNDS:-2}"

    # Show architecture diagram if available
    if type show_architecture_inline &>/dev/null; then
        show_architecture_inline "executing"
    fi

    printf "\n${BOLD}Retry Phase${NC}\n"
    printf "────────────────────────────────────────────────────────────────────────────────\n"

    local round=1
    while [[ $round -le $max_rounds ]]; do
        log "$run_id" "RETRY" "Starting retry round $round/$max_rounds"

        # Collect failed tasks
        local failed_tasks=()
        for judge_file in "$run_dir"/tasks/*.judge; do
            [[ ! -f "$judge_file" ]] && continue
            local verdict
            verdict=$(grep "^VERDICT=" "$judge_file" | cut -d= -f2)
            if [[ "$verdict" == "fail" ]]; then
                local task_id
                task_id=$(basename "$judge_file" .judge)
                failed_tasks+=("$task_id")
            fi
        done

        if [[ ${#failed_tasks[@]} -eq 0 ]]; then
            log "$run_id" "RETRY" "No failed tasks - retry complete"
            printf "${GREEN}All tasks now passing${NC}\n"
            return 0
        fi

        printf "${YELLOW}Retry Round %d/%d:${NC} %d failed tasks\n" "$round" "$max_rounds" "${#failed_tasks[@]}"

        local improved=0
        for task_id in "${failed_tasks[@]}"; do
            printf "  [retry] %s..." "$task_id"

            # Read judge feedback
            local judge_file="${run_dir}/tasks/${task_id}.judge"
            local judge_summary=""
            if [[ -f "$judge_file" ]]; then
                judge_summary=$(grep "^SUMMARY=" "$judge_file" | cut -d= -f2-)
            fi

            # Read worker notes (what the previous worker tried)
            local notes_file="${run_dir}/tasks/${task_id}.notes"
            local worker_notes=""
            [[ -f "$notes_file" ]] && worker_notes=$(cat "$notes_file")

            # PLANNER improves task spec based on feedback
            # (new worker will NOT see the old worker's notes directly)
            improve_task_spec_via_planner "$run_id" "$run_dir" "$task_id" \
                "$judge_summary" "$worker_notes"

            # Reset task for re-execution
            local spec_file="${run_dir}/tasks/${task_id}.spec"
            set_task_status "$run_dir" "$task_id" "pending"

            # Clean up old worktree if exists
            local old_worktree="${run_dir}/tasks/${task_id}.worktree"
            if [[ -f "$old_worktree" ]]; then
                local worktree_path
                worktree_path=$(cat "$old_worktree")
                if [[ -d "$worktree_path" ]]; then
                    git worktree remove --force "$worktree_path" 2>/dev/null || true
                fi
                rm -f "$old_worktree"
            fi

            # Re-execute worker (stays ignorant of previous attempt)
            launch_worker "$run_id" "$spec_file" "$run_dir"

            # Wait for worker to complete
            wait_for_task_completion "$run_dir" "$task_id" 300  # 5 min timeout

            # Re-judge the task
            judge_task "$run_id" "$run_dir" "$task_id"

            # Check if improved
            local new_verdict
            new_verdict=$(grep "^VERDICT=" "$judge_file" 2>/dev/null | cut -d= -f2)
            if [[ "$new_verdict" == "pass" ]]; then
                ((improved++))
                printf " ${GREEN}[pass]${NC} fixed on retry\n"
            else
                printf " ${RED}[fail]${NC} still failing\n"
            fi
        done

        if [[ $improved -eq 0 ]]; then
            log "$run_id" "RETRY" "No improvements in round $round - stopping"
            printf "${YELLOW}No improvements in round %d - stopping retry${NC}\n" "$round"
            break
        fi

        printf "${GREEN}Round %d: %d tasks improved${NC}\n" "$round" "$improved"
        ((round++))
    done

    # Report final status
    local final_pass=0
    local final_fail=0
    for judge_file in "$run_dir"/tasks/*.judge; do
        [[ ! -f "$judge_file" ]] && continue
        local verdict
        verdict=$(grep "^VERDICT=" "$judge_file" | cut -d= -f2)
        if [[ "$verdict" == "pass" ]]; then
            ((final_pass++))
        else
            ((final_fail++))
        fi
    done

    printf "\n${BOLD}Retry Summary:${NC} %d pass | %d fail\n" "$final_pass" "$final_fail"
}

# Wait for a task to complete (status changes from running)
# Usage: wait_for_task_completion <run_dir> <task_id> <timeout_seconds>
wait_for_task_completion() {
    local run_dir="$1"
    local task_id="$2"
    local timeout="${3:-300}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local status_file="${run_dir}/tasks/${task_id}.status"
        if [[ -f "$status_file" ]]; then
            local status
            status=$(cat "$status_file")
            if [[ "$status" == "done" || "$status" == "failed" ]]; then
                return 0
            fi
        fi
        sleep 2
        ((elapsed += 2))
    done

    # Timeout reached
    set_task_status "$run_dir" "$task_id" "failed"
    return 1
}

# ── Planner Improvement ─────────────────────────────────────────────────────

# Planner improves task spec based on judge feedback + worker notes
# The new worker sees an improved SPEC, not the old worker's notes directly
# Usage: improve_task_spec_via_planner <run_id> <run_dir> <task_id> <judge_feedback> <worker_notes>
improve_task_spec_via_planner() {
    local run_id="$1"
    local run_dir="$2"
    local task_id="$3"
    local judge_feedback="$4"
    local worker_notes="$5"

    local spec_file="${run_dir}/tasks/${task_id}.spec"

    # Increment retry count
    local current_retry
    current_retry=$(taskspec_get "$spec_file" "TASK_RETRY_COUNT" 2>/dev/null || echo "0")
    taskspec_set "$spec_file" "TASK_RETRY_COUNT" "$((current_retry + 1))"

    # Get current description
    local current_desc
    current_desc=$(taskspec_get_block "$spec_file" "TASK_DESCRIPTION")

    # Build enhanced description with retry guidance
    # The key: we give the new worker IMPROVED INSTRUCTIONS, not raw notes
    local enhanced_desc="${current_desc}

## RETRY GUIDANCE (Attempt $((current_retry + 2)))

The previous attempt failed. Here's what went wrong and how to fix it:

### Judge Feedback
${judge_feedback:-"No specific feedback available"}

### What the Previous Attempt Tried
${worker_notes:-"No notes available from previous attempt"}

### CRITICAL Instructions for This Attempt
1. **Interface Registry Compliance**: Ensure ALL HTML IDs and CSS classes match the interface registry EXACTLY
   - Do NOT invent new IDs or classes not in the registry
   - Do NOT use getElementById() for IDs not in the registry

2. **Check Before Creating**: Before creating any element with an id or class:
   - Verify it's in the interface registry
   - Use the exact spelling/casing from the registry

3. **Address the Specific Failures**: The judge found these issues - fix them:
   ${judge_feedback:-"Review the issues above"}

4. **Read Existing Files First**: Before modifying, read the current state of any files that might have been changed"

    # Update the task spec with enhanced description
    taskspec_set_block "$spec_file" "TASK_DESCRIPTION" "$enhanced_desc"

    log "$run_id" "RETRY" "Enhanced task spec for $task_id (attempt $((current_retry + 2)))"
}
