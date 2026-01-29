#!/usr/bin/env bash
# interactive.sh -- Interactive plan review UI
# Allows users to approve, edit, delete, add tasks, or request re-planning.
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_INTERACTIVE_LOADED:-}" ]] && return 0
_SWARMTOOL_INTERACTIVE_LOADED=1

# ── Plan Review Phase ───────────────────────────────────────────────────────

# Run the interactive plan review
# Usage: run_review_phase <run_id> <run_dir>
run_review_phase() {
    local run_id="$1"
    local run_dir="$2"

    while true; do
        echo ""
        print_header "Task Review"
        display_all_tasks "$run_dir"

        local task_count
        task_count=$(count_tasks "$run_dir")
        printf "  ${BOLD}%s tasks total${NC}\n" "$task_count"
        echo ""

        echo "Options:"
        printf "  ${BOLD}a${NC} - Approve and execute all tasks\n"
        printf "  ${BOLD}v${NC} - View task details\n"
        printf "  ${BOLD}e${NC} - Edit a task in \$EDITOR\n"
        printf "  ${BOLD}d${NC} - Delete a task\n"
        printf "  ${BOLD}n${NC} - Add a new task manually\n"
        printf "  ${BOLD}r${NC} - Re-plan (send feedback to planner)\n"
        printf "  ${BOLD}p${NC} - View full plan\n"
        printf "  ${BOLD}q${NC} - Quit without executing\n"
        echo ""
        printf "Choice: "
        read -r choice

        case "$choice" in
            a|A)
                echo ""
                printf "Execute ${BOLD}%s${NC} tasks? [y/N] " "$task_count"
                read -r confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    # Ask about auto-approve if not already set via CLI flag
                    if [[ "${AUTO_APPROVE:-false}" != "true" ]]; then
                        echo ""
                        printf "Auto-approve all subsequent steps (judging, merge)? [y/N] "
                        read -r auto_confirm
                        if [[ "$auto_confirm" =~ ^[Yy]$ ]]; then
                            AUTO_APPROVE=true
                            export AUTO_APPROVE
                            printf "${DIM}Running hands-off mode. You'll see progress but won't be prompted.${NC}\n"
                        fi
                    fi
                    return 0
                fi
                ;;
            v|V)
                _review_view_task "$run_dir"
                ;;
            e|E)
                _review_edit_task "$run_dir"
                ;;
            d|D)
                _review_delete_task "$run_dir"
                ;;
            n|N)
                _review_add_task "$run_id" "$run_dir"
                ;;
            r|R)
                _review_replan "$run_id" "$run_dir"
                ;;
            p|P)
                _review_show_plan "$run_dir"
                ;;
            q|Q)
                echo "Aborted."
                exit 0
                ;;
            *)
                echo "Invalid choice. Try again."
                ;;
        esac
    done
}

# ── View Task Details ───────────────────────────────────────────────────────

_review_view_task() {
    local run_dir="$1"

    echo ""
    printf "Task ID to view: "
    read -r task_id

    local spec_file="${run_dir}/tasks/${task_id}.spec"
    if [[ ! -f "$spec_file" ]]; then
        log_error "Task not found: ${task_id}"
        return 1
    fi

    echo ""
    print_section "Task: ${task_id}"

    echo "  Title:       $(taskspec_get "$spec_file" "TASK_TITLE")"
    echo "  Priority:    $(taskspec_get "$spec_file" "TASK_PRIORITY")"
    echo "  Model:       $(taskspec_get "$spec_file" "TASK_WORKER_MODEL")"
    echo "  Budget:      \$$(taskspec_get "$spec_file" "TASK_BUDGET_USD")"
    echo "  Depends on:  $(taskspec_get "$spec_file" "TASK_DEPENDS_ON")"
    echo ""

    echo "${BOLD}Description:${NC}"
    taskspec_get_block "$spec_file" "TASK_DESCRIPTION" | sed 's/^/  /'
    echo ""

    echo "${BOLD}Input Files:${NC}"
    taskspec_get_block "$spec_file" "TASK_INPUT_FILES" | sed 's/^/  /'
    echo ""

    echo "${BOLD}Expected Output:${NC}"
    taskspec_get_block "$spec_file" "TASK_EXPECTED_OUTPUT" | sed 's/^/  /'
    echo ""

    echo "${BOLD}Success Criteria:${NC}"
    taskspec_get_block "$spec_file" "TASK_SUCCESS_CRITERIA" | sed 's/^/  /'
    echo ""

    echo "${BOLD}Boundaries:${NC}"
    taskspec_get_block "$spec_file" "TASK_BOUNDARIES" | sed 's/^/  /'
    echo ""
}

# ── Edit Task ───────────────────────────────────────────────────────────────

_review_edit_task() {
    local run_dir="$1"

    echo ""
    printf "Task ID to edit: "
    read -r task_id

    local spec_file="${run_dir}/tasks/${task_id}.spec"
    if [[ ! -f "$spec_file" ]]; then
        log_error "Task not found: ${task_id}"
        return 1
    fi

    local editor="${EDITOR:-vi}"
    "$editor" "$spec_file"
    echo "Task ${task_id} updated."
}

# ── Delete Task ─────────────────────────────────────────────────────────────

_review_delete_task() {
    local run_dir="$1"

    echo ""
    printf "Task ID to delete: "
    read -r task_id

    local spec_file="${run_dir}/tasks/${task_id}.spec"
    if [[ ! -f "$spec_file" ]]; then
        log_error "Task not found: ${task_id}"
        return 1
    fi

    local title
    title=$(taskspec_get "$spec_file" "TASK_TITLE")
    printf "Delete task '${title}' (${task_id})? [y/N] "
    read -r confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "${run_dir}/tasks/${task_id}".{spec,status,result,log,judge,branch,worktree}
        echo "Task ${task_id} deleted."

        # Remove this task from other tasks' dependency lists
        for other_spec in "${run_dir}/tasks/"*.spec; do
            [[ -f "$other_spec" ]] || continue
            local deps
            deps=$(taskspec_get "$other_spec" "TASK_DEPENDS_ON")
            if [[ "$deps" == *"$task_id"* ]]; then
                # Remove this task_id from the deps list
                local new_deps
                new_deps=$(echo "$deps" | tr ',' '\n' | grep -v "^${task_id}$" | tr '\n' ',' | sed 's/,$//')
                taskspec_set "$other_spec" "TASK_DEPENDS_ON" "$new_deps"
            fi
        done
    fi
}

# ── Add Task ────────────────────────────────────────────────────────────────

_review_add_task() {
    local run_id="$1"
    local run_dir="$2"

    echo ""
    print_section "Add New Task"

    # Generate next task ID
    local existing_count
    existing_count=$(count_tasks "$run_dir")
    local new_id
    new_id="task-$(printf '%03d' $((existing_count + 1)))"

    printf "Task ID [${new_id}]: "
    read -r input_id
    [[ -n "$input_id" ]] && new_id="$input_id"

    printf "Title: "
    read -r title

    echo "Description (end with a line containing only '.'):"
    local description=""
    while IFS= read -r line; do
        [[ "$line" == "." ]] && break
        description="${description}${line}"$'\n'
    done

    echo "Input files (space-separated): "
    read -r input_files_str
    local input_files
    input_files=$(echo "$input_files_str" | tr ' ' '\n')

    echo "Expected output (end with '.'):"
    local expected_output=""
    while IFS= read -r line; do
        [[ "$line" == "." ]] && break
        expected_output="${expected_output}${line}"$'\n'
    done

    echo "Success criteria (end with '.'):"
    local success_criteria=""
    while IFS= read -r line; do
        [[ "$line" == "." ]] && break
        success_criteria="${success_criteria}${line}"$'\n'
    done

    echo "Boundaries (end with '.'):"
    local boundaries=""
    while IFS= read -r line; do
        [[ "$line" == "." ]] && break
        boundaries="${boundaries}${line}"$'\n'
    done

    printf "Dependencies (comma-separated task IDs, or empty): "
    read -r depends_on

    printf "Priority [5]: "
    read -r priority
    priority="${priority:-5}"

    create_task_spec "$run_dir" "$new_id" "$title" "$description" \
        "$input_files" "$expected_output" "$success_criteria" "$boundaries" \
        "$depends_on" "$priority"

    echo ""
    printf "${GREEN}Task ${new_id} created.${NC}\n"
}

# ── Re-plan ─────────────────────────────────────────────────────────────────

_review_replan() {
    local run_id="$1"
    local run_dir="$2"

    echo ""
    echo "Provide feedback for the planner (what should change?):"
    printf "> "
    read -r feedback

    if [[ -z "$feedback" ]]; then
        echo "No feedback provided. Skipping re-plan."
        return 0
    fi

    log "$run_id" "PLANNER" "Re-planning with feedback: $feedback"
    printf "${BOLD}Re-planning...${NC}\n"

    # Get the original goal
    local goal
    goal=$(get_run_meta "$run_dir" "GOAL")

    # Clear existing tasks
    rm -f "${run_dir}/tasks/"*.{spec,status}

    # Re-run planner with the feedback appended
    local augmented_goal="${goal}

REVISION FEEDBACK: ${feedback}"

    run_planning_phase "$run_id" "$run_dir" "$augmented_goal"
}

# ── Show Full Plan ──────────────────────────────────────────────────────────

_review_show_plan() {
    local run_dir="$1"

    local plan_file="${run_dir}/plan.md"
    if [[ -f "$plan_file" ]]; then
        echo ""
        cat "$plan_file"
    else
        echo "No plan file found."
    fi
}
