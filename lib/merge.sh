#!/usr/bin/env bash
# merge.sh -- Merge pipeline: auto-merge, sequential merge, conflict resolution
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_MERGE_LOADED:-}" ]] && return 0
_SWARMTOOL_MERGE_LOADED=1

# ── Merge Order ─────────────────────────────────────────────────────────────

# Determine topological merge order based on dependencies and priority
# Usage: determine_merge_order <run_dir>
# Outputs: ordered task IDs, one per line
determine_merge_order() {
    local run_dir="$1"

    # Convert to absolute path
    local abs_run_dir
    abs_run_dir=$(cd "$run_dir" 2>/dev/null && pwd) || abs_run_dir="$run_dir"

    # Collect tasks that passed judging
    local passed_tasks=()
    for judge_file in "${abs_run_dir}/tasks/"*.judge; do
        [[ -f "$judge_file" ]] || continue
        local verdict
        verdict=$(grep "^VERDICT=" "$judge_file" | cut -d'=' -f2-)
        if [[ "$verdict" == "pass" ]]; then
            local task_id
            task_id=$(basename "$judge_file" .judge)
            passed_tasks+=("$task_id")
        fi
    done

    if [[ ${#passed_tasks[@]} -eq 0 ]]; then
        return 0
    fi

    # Topological sort: tasks with no dependencies first, then by priority
    local ordered=()
    local merged_ids=()

    # Copy passed_tasks to remaining (Bash 3.2 safe)
    local remaining=()
    local cp_idx
    for ((cp_idx=0; cp_idx<${#passed_tasks[@]}; cp_idx++)); do
        remaining+=("${passed_tasks[$cp_idx]}")
    done

    while [[ ${#remaining[@]} -gt 0 ]]; do
        local progress=false
        local next_remaining=()

        local r_idx
        for ((r_idx=0; r_idx<${#remaining[@]}; r_idx++)); do
            local task_id="${remaining[$r_idx]}"
            local spec_file="${abs_run_dir}/tasks/${task_id}.spec"
            local deps
            deps=$(taskspec_get "$spec_file" "TASK_DEPENDS_ON")

            local deps_met=true
            if [[ -n "$deps" ]]; then
                local IFS=','
                for dep in $deps; do
                    dep=$(echo "$dep" | tr -d ' ')
                    local found=false
                    local m_idx
                    for ((m_idx=0; m_idx<${#merged_ids[@]}; m_idx++)); do
                        [[ "${merged_ids[$m_idx]}" == "$dep" ]] && found=true && break
                    done
                    [[ "$found" != "true" ]] && deps_met=false && break
                done
                unset IFS
            fi

            if [[ "$deps_met" == "true" ]]; then
                ordered+=("$task_id")
                merged_ids+=("$task_id")
                progress=true
            else
                next_remaining+=("$task_id")
            fi
        done

        # Copy next_remaining to remaining (Bash 3.2 safe)
        remaining=()
        for ((cp_idx=0; cp_idx<${#next_remaining[@]}; cp_idx++)); do
            remaining+=("${next_remaining[$cp_idx]}")
        done

        if [[ "$progress" != "true" && ${#remaining[@]} -gt 0 ]]; then
            # Circular dependency or unresolvable -- add remaining
            log_warn "Could not resolve all dependencies. Adding remaining tasks in order."
            ordered+=("${remaining[@]}")
            break
        fi
    done

    printf '%s\n' "${ordered[@]}"
}

# ── Merge Pipeline ──────────────────────────────────────────────────────────

# Run the full merge pipeline
# Usage: run_merge_phase <run_id> <run_dir>
run_merge_phase() {
    local run_id="$1" run_dir="$2"
    local merge_dir="${run_dir}/merge"
    local merge_log="${merge_dir}/merge.log"

    print_header "Merge"

    # Show architecture diagram if available
    if type show_architecture_inline &>/dev/null; then
        show_architecture_inline "merging"
    fi

    # Get base branch and commit
    local base_branch base_commit
    base_branch=$(get_run_meta "$run_dir" "BASE_BRANCH")
    base_commit=$(get_run_meta "$run_dir" "BASE_COMMIT")

    # Determine merge order
    local merge_tasks=()
    while IFS= read -r tid; do
        [[ -n "$tid" ]] && merge_tasks+=("$tid")
    done < <(determine_merge_order "$run_dir")

    # Save merge order
    printf '%s\n' "${merge_tasks[@]:-}" > "${merge_dir}/merge.order"

    if [[ ${#merge_tasks[@]} -eq 0 ]]; then
        log "$run_id" "MERGE" "No tasks passed judging. Nothing to merge."
        printf "${YELLOW}No tasks passed judging. Nothing to merge.${NC}\n"
        echo "no_tasks" > "${merge_dir}/merge.status"
        return 0
    fi

    local total_tasks=${#merge_tasks[@]}
    local current_task=0

    printf "Merging ${BOLD}%d${NC} task branches...\n\n" "$total_tasks"
    echo "in_progress" > "${merge_dir}/merge.status"

    # Stash current state and create integration branch
    local current_branch
    current_branch=$(get_current_branch)
    local integration_branch="swarmtool/integrate/${run_id}"

    git checkout -b "$integration_branch" "$base_commit" >>"$merge_log" 2>&1 || {
        log_error "Failed to create integration branch"
        echo "failed" > "${merge_dir}/merge.status"
        git checkout -- .swarmtool 2>/dev/null || true
        git checkout "$current_branch" 2>/dev/null
        return 1
    }

    log "$run_id" "MERGE" "Created integration branch: ${integration_branch}"

    # ── Stage 1: Auto-merge ─────────────────────────────────────────────
    local failed_merges=()
    local success_count=0

    for task_id in "${merge_tasks[@]}"; do
        ((current_task++))

        # Show progress bar
        if type show_phase_progress &>/dev/null; then
            show_phase_progress "Merging" "$current_task" "$total_tasks" "merging $task_id"
        fi

        local spec_file="${run_dir}/tasks/${task_id}.spec"
        local task_branch
        task_branch=$(taskspec_get "$spec_file" "TASK_BRANCH")
        local title
        title=$(taskspec_get "$spec_file" "TASK_TITLE")

        # Check if branch exists
        if ! git rev-parse --verify "$task_branch" >/dev/null 2>&1; then
            printf "  ${YELLOW}[skip]${NC} %s (branch not found: %s)\n" "$title" "$task_branch"
            log "$run_id" "MERGE" "Skipping ${task_id}: branch ${task_branch} not found"
            continue
        fi

        # Check if branch has any commits beyond base
        local branch_commits
        branch_commits=$(git log --oneline "${base_commit}..${task_branch}" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$branch_commits" -eq 0 ]]; then
            printf "  ${DIM}[skip]${NC} %s (no changes)\n" "$title"
            continue
        fi

        # Attempt auto-merge
        if git merge --no-edit "$task_branch" >>"$merge_log" 2>&1; then
            printf "  ${GREEN}[merged]${NC} %s\n" "$title"
            success_count=$((success_count + 1))
            log "$run_id" "MERGE" "Auto-merged: ${task_id} (${task_branch})"
        else
            git merge --abort 2>/dev/null
            printf "  ${YELLOW}[conflict]${NC} %s\n" "$title"
            failed_merges+=("$task_id")
            log "$run_id" "MERGE" "Conflict: ${task_id} (${task_branch})"
        fi
    done

    # ── Stage 2: Claude-assisted conflict resolution ────────────────────
    if [[ ${#failed_merges[@]} -gt 0 ]]; then
        echo ""
        printf "Resolving ${BOLD}%d${NC} merge conflicts with Claude Code...\n\n" "${#failed_merges[@]}"

        for task_id in "${failed_merges[@]}"; do
            local spec_file="${run_dir}/tasks/${task_id}.spec"
            local task_branch
            task_branch=$(taskspec_get "$spec_file" "TASK_BRANCH")
            local title
            title=$(taskspec_get "$spec_file" "TASK_TITLE")

            log "$run_id" "MERGE" "Claude-assisted merge: ${task_id}"

            # Start the merge (will have conflicts)
            git merge --no-commit --no-ff "$task_branch" >>"$merge_log" 2>&1 || true

            # Find conflicted files
            local conflict_files
            conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null)

            if [[ -z "$conflict_files" ]]; then
                # No actual conflicts -- maybe already resolved
                git commit --no-edit >>"$merge_log" 2>&1 || git merge --abort 2>/dev/null
                printf "  ${GREEN}[resolved]${NC} %s (no actual conflicts)\n" "$title"
                success_count=$((success_count + 1))
                continue
            fi

            # Build merge resolution prompt
            local merge_prompt
            merge_prompt=$(build_merge_prompt "$task_branch" "$conflict_files")

            local system_prompt=""
            local system_prompt_file="${SWARMTOOL_DIR}/prompts/merge_resolve.txt"
            [[ -f "$system_prompt_file" ]] && system_prompt=$(cat "$system_prompt_file")

            # Get provider:model spec for merger
            local merger_spec
            merger_spec=$(resolve_provider_spec merger)
            local merge_budget="${SWARMTOOL_MERGE_BUDGET:-0.50}"

            # Invoke LLM to resolve conflicts
            invoke_llm "$merger_spec" "$merge_prompt" \
                --system-prompt "$system_prompt" \
                --allowed-tools "Read,Edit,Glob,Grep,Bash(git\ diff:*),Bash(git\ status:*)" \
                --max-turns 20 \
                >>"$merge_log" 2>&1 || true

            # Check if conflicts are resolved
            local remaining_conflicts
            remaining_conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null)

            if [[ -z "$remaining_conflicts" ]]; then
                git add -A
                git commit -m "swarmtool: merge ${task_id} with conflict resolution" >>"$merge_log" 2>&1
                printf "  ${GREEN}[resolved]${NC} %s\n" "$title"
                success_count=$((success_count + 1))
                log "$run_id" "MERGE" "Resolved: ${task_id}"
            else
                git merge --abort 2>/dev/null
                printf "  ${RED}[failed]${NC} %s (unresolved conflicts)\n" "$title"
                log "$run_id" "MERGE" "FAILED to resolve: ${task_id}"
            fi
        done
    fi

    echo ""

    # ── Stage 3: Integration validation gate ────────────────────────────
    printf "${DIM}Running integration validation...${NC}\n"

    local integration_issues=""
    if type analyze_integration_issues &>/dev/null; then
        integration_issues=$(analyze_integration_issues ".")
    fi

    if [[ -n "$integration_issues" ]]; then
        printf "\n${YELLOW}Integration issues detected:${NC}\n"
        echo "$integration_issues" | head -20

        # Auto-fix if enabled and fix functions are available
        if [[ "${SWARMTOOL_AUTO_FIX:-true}" == "true" ]] && type run_fixer_agent &>/dev/null; then
            printf "\n${DIM}Running automatic fix...${NC}\n"
            run_fixer_agent "" "$integration_issues" "." >>"$merge_log" 2>&1 || true

            # Commit any fixer changes (required before checkout)
            if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
                git add -A
                git commit -m "swarmtool: auto-fix integration issues" >>"$merge_log" 2>&1 || true
            fi

            # Re-validate after fix
            integration_issues=$(analyze_integration_issues ".")
            if [[ -z "$integration_issues" ]]; then
                printf "${GREEN}Integration issues resolved.${NC}\n"
            else
                printf "${YELLOW}Some issues remain after auto-fix:${NC}\n"
                echo "$integration_issues" | head -10
            fi
        else
            printf "${YELLOW}Auto-fix disabled or unavailable. Manual fix may be needed.${NC}\n"
        fi
    else
        printf "${GREEN}Integration validation passed.${NC}\n"
    fi

    echo ""

    # ── Stage 4: Final build validation ─────────────────────────────────
    if [[ "${SWARMTOOL_FINAL_VALIDATION:-true}" == "true" ]]; then
        printf "${DIM}Running final build validation...${NC}\n"

        local validation_errors=""

        # Run basic checks on the integration branch
        if [[ -f "package.json" ]] && command -v npm >/dev/null 2>&1; then
            if jq -e '.scripts.build' package.json >/dev/null 2>&1; then
                npm run build >>"$merge_log" 2>&1 || validation_errors="Build failed; "
            fi
        fi

        if [[ -n "$validation_errors" ]]; then
            printf "${YELLOW}Final validation warnings:${NC} %s\n" "$validation_errors"
            log "$run_id" "MERGE" "Validation warnings: ${validation_errors}"
        else
            printf "${GREEN}Final build validation passed.${NC}\n"
        fi
    fi

    # ── Stage 5: Merge into base branch ─────────────────────────────────
    echo ""
    local confirm="n"
    if [[ "${AUTO_APPROVE:-false}" == "true" ]]; then
        printf "Merging ${BOLD}%d${NC} changes into ${BOLD}%s${NC}... (auto-approved)\n" "$success_count" "$base_branch"
        confirm="y"
    else
        printf "Merge ${BOLD}%d${NC} changes into ${BOLD}%s${NC}? [y/N] " "$success_count" "$base_branch"
        read -r confirm
    fi

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # Discard uncommitted changes to .swarmtool files before checkout
        # (merge.log is just a log file, we don't need to preserve uncommitted changes)
        git checkout -- .swarmtool 2>/dev/null || true
        git checkout "$base_branch" >>"$merge_log" 2>&1
        if git merge --no-edit "$integration_branch" >>"$merge_log" 2>&1; then
            printf "${GREEN}Successfully merged into %s.${NC}\n" "$base_branch"
            echo "complete" > "${merge_dir}/merge.status"
            log "$run_id" "MERGE" "Merged into ${base_branch}"

            # Clean up integration branch
            git branch -D "$integration_branch" >>"$merge_log" 2>&1 || true
        else
            printf "${RED}Failed to merge into %s.${NC}\n" "$base_branch"
            echo "failed" > "${merge_dir}/merge.status"
            git merge --abort 2>/dev/null
            git checkout -- .swarmtool 2>/dev/null || true
            git checkout "$base_branch" 2>/dev/null
            log "$run_id" "MERGE" "FAILED to merge into ${base_branch}"
        fi
    else
        printf "Integration branch preserved: ${BOLD}%s${NC}\n" "$integration_branch"
        printf "Merge manually with: git merge %s\n" "$integration_branch"
        git checkout -- .swarmtool 2>/dev/null || true
        git checkout "$base_branch" >>"$merge_log" 2>&1
        echo "preserved" > "${merge_dir}/merge.status"
    fi
}
