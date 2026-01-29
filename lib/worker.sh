#!/usr/bin/env bash
# worker.sh -- Worker lifecycle: worktree setup, Claude Code invocation, teardown
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_WORKER_LOADED:-}" ]] && return 0
_SWARMTOOL_WORKER_LOADED=1

# ── Worker Invocation ───────────────────────────────────────────────────────

# Invoke Claude Code CLI with retry logic for rate limits
# Usage: invoke_claude_with_retry <args...>
invoke_claude_with_retry() {
    local max_retries="${SWARMTOOL_WORKER_MAX_RETRIES:-2}"
    local retry_delay="${SWARMTOOL_RETRY_DELAY:-10}"
    local attempt=0

    while [[ $attempt -le $max_retries ]]; do
        # Execute the claude command
        "$@"
        local exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -le $max_retries ]]; then
            log "${CURRENT_RUN_ID:-}" "WORKER" "Claude exited with code ${exit_code}. Retry ${attempt}/${max_retries} in ${retry_delay}s"
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
        fi
    done

    return 1
}

# ── Worker Lifecycle ────────────────────────────────────────────────────────

# Launch a worker for a single task
# This function runs in a subshell (backgrounded by the execution loop)
# Usage: launch_worker <run_id> <run_dir> <task_id>
launch_worker() {
    local run_id="$1"
    local run_dir="$2"
    local task_id="$3"
    local spec_file="${run_dir}/tasks/${task_id}.spec"

    local base_commit task_branch worktree_path
    base_commit=$(get_run_meta "$run_dir" "BASE_COMMIT")
    task_branch=$(taskspec_get "$spec_file" "TASK_BRANCH")
    worktree_path="${SWARMTOOL_STATE_DIR}/worktrees/${run_id}/${task_id}"

    local result_file="${run_dir}/tasks/${task_id}.result"
    local log_file="${run_dir}/tasks/${task_id}.log"

    log "$run_id" "WORKER" "Starting task: ${task_id} ($(taskspec_get "$spec_file" "TASK_TITLE"))"

    # ── Step 1: Set up git worktree ───────────────────────────────────────
    # Clean up any existing worktree at this path (from failed previous runs)
    if [[ -d "$worktree_path" ]]; then
        git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi

    # Remove branch if it exists (from failed previous runs)
    git branch -D "$task_branch" 2>/dev/null || true

    # Prune stale worktree references
    git worktree prune 2>/dev/null || true

    # Create the branch from base commit
    git branch "$task_branch" "$base_commit" 2>/dev/null || true

    # Create worktree directory
    mkdir -p "$(dirname "$worktree_path")"

    if ! git worktree add "$worktree_path" "$task_branch" 2>>"$log_file"; then
        log "$run_id" "WORKER" "FAILED to create worktree for ${task_id}"
        set_task_status "$run_dir" "$task_id" "failed"
        echo "Worktree creation failed. Check ${log_file} for details." > "$result_file"
        return 1
    fi

    # Record worktree path
    echo "$worktree_path" > "${run_dir}/tasks/${task_id}.worktree"

    # Update status to running
    set_task_status "$run_dir" "$task_id" "running"

    # Record PID
    echo "$$" > "${run_dir}/pids/${task_id}.pid"

    # ── Step 2: Build the prompt ──────────────────────────────────────────
    local worker_prompt
    worker_prompt=$(build_worker_prompt "$spec_file")

    # ── Step 3: Determine worker settings ─────────────────────────────────
    local worker_model budget
    worker_model=$(taskspec_get "$spec_file" "TASK_WORKER_MODEL")
    worker_model="${worker_model:-${SWARMTOOL_WORKER_MODEL:-sonnet}}"

    budget=$(taskspec_get "$spec_file" "TASK_BUDGET_USD")
    budget="${budget:-${SWARMTOOL_WORKER_BUDGET:-1.00}}"

    local system_prompt_file="${SWARMTOOL_DIR}/prompts/worker_system.txt"
    local system_prompt=""
    [[ -f "$system_prompt_file" ]] && system_prompt=$(cat "$system_prompt_file")

    # ── Step 4: Invoke Claude Code CLI ────────────────────────────────────
    # Convert to absolute path for the worktree
    local abs_worktree
    abs_worktree=$(cd "$worktree_path" && pwd)

    local claude_exit_code=0

    # Build claude command arguments
    local claude_args=(-p)
    claude_args+=(--model "$worker_model")

    if [[ -n "$system_prompt" ]]; then
        claude_args+=(--system-prompt "$system_prompt")
    fi

    claude_args+=(--output-format json)
    claude_args+=(--allowedTools "Bash,Edit,Read,Write,Glob,Grep")
    claude_args+=(--max-turns 50)

    # Execute Claude Code in the worktree directory
    (
        cd "$abs_worktree" || exit 1
        invoke_claude_with_retry claude "${claude_args[@]}" "$worker_prompt"
    ) > "$result_file" 2>> "$log_file"
    claude_exit_code=$?

    # ── Step 5: Capture results ───────────────────────────────────────────
    if [[ $claude_exit_code -eq 0 ]]; then
        # Check if the worker made any file changes
        local changes_made=""
        changes_made=$(cd "$abs_worktree" && git diff --stat HEAD 2>/dev/null || echo "")

        # Also check for untracked files
        local untracked=""
        untracked=$(cd "$abs_worktree" && git ls-files --others --exclude-standard 2>/dev/null || echo "")

        if [[ -n "$changes_made" || -n "$untracked" ]]; then
            # Commit the worker's changes
            (
                cd "$abs_worktree" || exit 1
                git add -A
                git commit -m "swarmtool: ${task_id} - $(taskspec_get "$spec_file" "TASK_TITLE")" \
                    --author="swarmtool <swarmtool@local>" \
                    2>>"${ORIGINAL_PWD}/${log_file}" || true
            )
            set_task_status "$run_dir" "$task_id" "done"
            log "$run_id" "WORKER" "Task ${task_id} completed with changes"
        else
            set_task_status "$run_dir" "$task_id" "done"
            log "$run_id" "WORKER" "Task ${task_id} completed (no file changes)"
        fi
    else
        # Check retry count
        local retry_count
        retry_count=$(taskspec_get "$spec_file" "TASK_RETRY_COUNT")
        retry_count="${retry_count:-0}"
        local max_retries
        max_retries=$(taskspec_get "$spec_file" "TASK_MAX_RETRIES")
        max_retries="${max_retries:-${SWARMTOOL_WORKER_MAX_RETRIES:-2}}"

        set_task_status "$run_dir" "$task_id" "failed"
        log "$run_id" "WORKER" "Task ${task_id} FAILED (exit code ${claude_exit_code})"
    fi

    # ── Step 6: Cleanup PID file ──────────────────────────────────────────
    rm -f "${run_dir}/pids/${task_id}.pid"

    return $claude_exit_code
}

# ── Execution Phase ─────────────────────────────────────────────────────────

# Run all tasks in parallel with dependency-aware scheduling
# Uses Bash 3.2-compatible polling (no wait -n)
# Usage: run_execution_phase <run_id> <run_dir>
run_execution_phase() {
    local run_id="$1"
    local run_dir="$2"

    local task_count
    task_count=$(count_tasks "$run_dir")
    local max_workers
    max_workers=$(detect_max_workers "$task_count")

    log "$run_id" "EXEC" "Starting execution: ${task_count} tasks, max ${max_workers} workers"
    echo ""
    printf "${BOLD}Executing with %d max concurrent workers${NC}\n" "$max_workers"
    echo ""

    # Track active workers: arrays of PIDs and their task IDs
    local active_pids=()
    local active_tasks=()

    while true; do
        # Check if shutdown was requested
        [[ "$SHUTDOWN_REQUESTED" == "true" ]] && break

        # ── Reap finished workers ─────────────────────────────────────────
        local new_pids=()
        local new_tasks=()
        local i=0
        while [[ $i -lt ${#active_pids[@]} ]]; do
            local pid="${active_pids[$i]}"
            local tid="${active_tasks[$i]}"

            if kill -0 "$pid" 2>/dev/null; then
                # Still running
                new_pids+=("$pid")
                new_tasks+=("$tid")
            else
                # Finished -- wait to get exit code
                wait "$pid" 2>/dev/null || true
                local title
                title=$(taskspec_get "${run_dir}/tasks/${tid}.spec" "TASK_TITLE")
                local status
                status=$(get_task_status "$run_dir" "$tid")

                if [[ "$status" == "done" ]]; then
                    printf "  ${GREEN}[done]${NC} %s\n" "$title"
                else
                    printf "  ${RED}[fail]${NC} %s\n" "$title"
                fi

                # Update WORKER_PIDS for signal handler
                WORKER_PIDS=()
                local wp_idx
                for ((wp_idx=0; wp_idx<${#new_pids[@]}; wp_idx++)); do
                    [[ -n "${new_pids[$wp_idx]}" ]] && WORKER_PIDS+=("${new_pids[$wp_idx]}:unused")
                done
            fi
            i=$((i + 1))
        done

        # Copy arrays (avoid :- which creates empty element in Bash 3.2)
        active_pids=()
        active_tasks=()
        local copy_idx
        for ((copy_idx=0; copy_idx<${#new_pids[@]}; copy_idx++)); do
            [[ -n "${new_pids[$copy_idx]}" ]] && active_pids+=("${new_pids[$copy_idx]}")
        done
        for ((copy_idx=0; copy_idx<${#new_tasks[@]}; copy_idx++)); do
            [[ -n "${new_tasks[$copy_idx]}" ]] && active_tasks+=("${new_tasks[$copy_idx]}")
        done

        # ── Get ready tasks ───────────────────────────────────────────────
        local ready_tasks=()
        local ready_output
        ready_output=$(list_ready_tasks "$run_dir")
        if [[ -n "$ready_output" ]]; then
            while IFS= read -r tid; do
                [[ -n "$tid" ]] && ready_tasks+=("$tid")
            done <<< "$ready_output"
        fi

        # ── Launch new workers ────────────────────────────────────────────
        local active_count="${#active_pids[@]}"

        # Use index-based iteration for Bash 3.2 compatibility
        local loop_idx
        for ((loop_idx=0; loop_idx<${#ready_tasks[@]}; loop_idx++)); do
            local tid="${ready_tasks[$loop_idx]}"

            [[ -z "$tid" ]] && continue
            [[ $active_count -ge $max_workers ]] && break

            local title
            title=$(taskspec_get "${run_dir}/tasks/${tid}.spec" "TASK_TITLE")
            printf "  ${BLUE}[start]${NC} %s\n" "$title"

            # Launch worker in background subshell
            launch_worker "$run_id" "$run_dir" "$tid" &
            local pid=$!
            active_pids+=("$pid")
            active_tasks+=("$tid")
            active_count=$((active_count + 1))

            # Track for signal handler
            WORKER_PIDS+=("$pid:$tid")
        done

        # ── Check if we're done ───────────────────────────────────────────
        local pending_count running_count
        pending_count=$(count_tasks "$run_dir" "pending")
        running_count=$(count_tasks "$run_dir" "running")

        if [[ $pending_count -eq 0 && $running_count -eq 0 && ${#active_pids[@]} -eq 0 ]]; then
            break
        fi

        # No ready tasks and nothing running = possible deadlock (unresolvable dependencies)
        if [[ ${#ready_tasks[@]} -eq 0 && ${#active_pids[@]} -eq 0 && $pending_count -gt 0 ]]; then
            log_error "Deadlock detected: ${pending_count} tasks pending but none are ready (dependency cycle?)"
            break
        fi

        # Poll interval
        sleep 2

        # Show progress periodically
        display_progress "$run_dir"
    done

    echo ""
    display_progress "$run_dir"
    echo ""
}
