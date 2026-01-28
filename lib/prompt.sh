#!/usr/bin/env bash
# prompt.sh -- Prompt template rendering for planner, worker, judge, merge
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_PROMPT_LOADED:-}" ]] && return 0
_SWARMTOOL_PROMPT_LOADED=1

# ── Template Rendering ──────────────────────────────────────────────────────

# Render a prompt template file, substituting {{VARIABLE}} placeholders
# Usage: render_template <template_file> [VAR=value ...]
# Example: render_template prompts/worker_execute.txt TITLE="Add auth" DESCRIPTION="..."
render_template() {
    local template_file="$1"
    shift

    if [[ ! -f "$template_file" ]]; then
        log_error "Template not found: $template_file"
        return 1
    fi

    local content
    content=$(cat "$template_file")

    # Replace each VAR=value pair
    while [[ $# -gt 0 ]]; do
        local pair="$1"
        local key="${pair%%=*}"
        local value="${pair#*=}"
        # Use awk for safe substitution (handles special chars in value)
        content=$(echo "$content" | awk -v k="{{${key}}}" -v v="$value" '{gsub(k, v); print}')
        shift
    done

    echo "$content"
}

# ── Worker Prompt Construction ──────────────────────────────────────────────

# Build the full worker prompt from a task spec file
# Usage: build_worker_prompt <spec_file>
build_worker_prompt() {
    local spec_file="$1"

    local title description input_files expected_output success_criteria boundaries
    title=$(taskspec_get "$spec_file" "TASK_TITLE")
    description=$(taskspec_get_block "$spec_file" "TASK_DESCRIPTION")
    input_files=$(taskspec_get_block "$spec_file" "TASK_INPUT_FILES")
    expected_output=$(taskspec_get_block "$spec_file" "TASK_EXPECTED_OUTPUT")
    success_criteria=$(taskspec_get_block "$spec_file" "TASK_SUCCESS_CRITERIA")
    boundaries=$(taskspec_get_block "$spec_file" "TASK_BOUNDARIES")

    local template_file="${SWARMTOOL_DIR}/prompts/worker_execute.txt"

    if [[ -f "$template_file" ]]; then
        render_template "$template_file" \
            "TITLE=${title}" \
            "DESCRIPTION=${description}" \
            "INPUT_FILES=${input_files}" \
            "EXPECTED_OUTPUT=${expected_output}" \
            "SUCCESS_CRITERIA=${success_criteria}" \
            "BOUNDARIES=${boundaries}"
    else
        # Fallback: inline prompt construction
        cat <<PROMPT
# Task: ${title}

## Description
${description}

## Input Files (start by reading these)
${input_files}

## Expected Output
${expected_output}

## Success Criteria
${success_criteria}

## Boundaries (DO NOT violate these)
${boundaries}

## Instructions
1. Read the input files listed above to understand the current code.
2. Implement the changes described in the description.
3. Verify your changes meet all success criteria.
4. Do not make changes outside the boundaries specified above.
5. When done, ensure all files are saved. Do not run git commands.
PROMPT
    fi
}

# ── Planner Prompt Construction ─────────────────────────────────────────────

# Build the planner decomposition prompt
# Usage: build_planner_prompt <goal>
build_planner_prompt() {
    local goal="$1"

    local template_file="${SWARMTOOL_DIR}/prompts/planner_decompose.txt"

    if [[ -f "$template_file" ]]; then
        render_template "$template_file" "GOAL=${goal}"
    else
        cat <<PROMPT
# Goal
${goal}

Analyze the codebase and decompose this goal into independent, parallelizable tasks.
Each task should be completable by a single agent working in isolation.
PROMPT
    fi
}

# ── Judge Prompt Construction ───────────────────────────────────────────────

# Build the judge evaluation prompt for a task
# Usage: build_judge_prompt <run_dir> <task_id>
build_judge_prompt() {
    local run_dir="$1" task_id="$2"
    local spec_file="${run_dir}/tasks/${task_id}.spec"
    local result_file="${run_dir}/tasks/${task_id}.result"

    local title success_criteria worker_result
    title=$(taskspec_get "$spec_file" "TASK_TITLE")
    success_criteria=$(taskspec_get_block "$spec_file" "TASK_SUCCESS_CRITERIA")
    worker_result=""
    [[ -f "$result_file" ]] && worker_result=$(cat "$result_file")

    local template_file="${SWARMTOOL_DIR}/prompts/judge_evaluate.txt"

    if [[ -f "$template_file" ]]; then
        render_template "$template_file" \
            "TITLE=${title}" \
            "SUCCESS_CRITERIA=${success_criteria}" \
            "WORKER_RESULT=${worker_result}" \
            "TASK_ID=${task_id}"
    else
        cat <<PROMPT
# Evaluate Task: ${title}

## Success Criteria
${success_criteria}

## Worker Output
${worker_result}

Review the changes made by the worker. Determine if the success criteria are met.
Respond with a verdict: pass, fail, or needs_revision.
PROMPT
    fi
}

# ── Merge Prompt Construction ───────────────────────────────────────────────

# Build the merge conflict resolution prompt
# Usage: build_merge_prompt <branch_name> <conflict_files>
build_merge_prompt() {
    local branch_name="$1" conflict_files="$2"

    local template_file="${SWARMTOOL_DIR}/prompts/merge_resolve.txt"

    if [[ -f "$template_file" ]]; then
        render_template "$template_file" \
            "BRANCH=${branch_name}" \
            "CONFLICT_FILES=${conflict_files}"
    else
        cat <<PROMPT
# Merge Conflict Resolution

Branch being merged: ${branch_name}

The following files have merge conflicts:
${conflict_files}

For each conflicted file:
1. Read the file to see the conflict markers (<<<<<<< / ======= / >>>>>>>)
2. Understand what both sides intended
3. Edit the file to resolve the conflict, keeping the correct combined behavior
4. Remove all conflict markers

Do NOT add any new functionality. Only resolve the conflicts.
PROMPT
    fi
}
