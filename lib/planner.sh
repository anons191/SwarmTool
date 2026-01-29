#!/usr/bin/env bash
# planner.sh -- Invoke Claude Code as the planner to decompose goals into tasks
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_PLANNER_LOADED:-}" ]] && return 0
_SWARMTOOL_PLANNER_LOADED=1

# JSON schema for the planner's structured output
PLANNER_JSON_SCHEMA='{
  "type": "object",
  "properties": {
    "plan_summary": { "type": "string" },
    "tasks": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "id": { "type": "string" },
          "title": { "type": "string" },
          "description": { "type": "string" },
          "input_files": { "type": "array", "items": { "type": "string" } },
          "expected_output": { "type": "string" },
          "success_criteria": { "type": "string" },
          "boundaries": { "type": "string" },
          "depends_on": { "type": "array", "items": { "type": "string" } },
          "priority": { "type": "integer" },
          "estimated_complexity": { "type": "string", "enum": ["low", "medium", "high"] }
        },
        "required": ["id", "title", "description", "input_files", "expected_output", "success_criteria", "boundaries"]
      }
    }
  },
  "required": ["plan_summary", "tasks"]
}'

# ── Planning Phase ──────────────────────────────────────────────────────────

# Run the planning phase: invoke Claude Code to decompose the goal
# Usage: run_planning_phase <run_id> <run_dir> <goal>
run_planning_phase() {
    local run_id="$1"
    local run_dir="$2"
    local goal="$3"

    log "$run_id" "PLANNER" "Decomposing goal: $goal"
    printf "${BOLD}Planning...${NC} Analyzing codebase and decomposing goal.\n"
    echo ""

    # Build the planner prompt
    local planner_prompt
    planner_prompt=$(build_planner_prompt "$goal")

    # Load system prompt
    local system_prompt=""
    local system_prompt_file="${SWARMTOOL_DIR}/prompts/planner_system.txt"
    [[ -f "$system_prompt_file" ]] && system_prompt=$(cat "$system_prompt_file")

    local planner_model="${SWARMTOOL_PLANNER_MODEL:-opus}"
    local planner_budget="${SWARMTOOL_PLANNER_BUDGET:-2.00}"

    # Invoke Claude Code as planner
    local raw_output=""
    local planner_log="${run_dir}/planner.log"

    local claude_args=(-p)
    claude_args+=(--model "$planner_model")

    if [[ -n "$system_prompt" ]]; then
        claude_args+=(--system-prompt "$system_prompt")
    fi

    claude_args+=(--output-format json)
    claude_args+=(--allowedTools "Read,Glob,Grep,Bash(find:*),Bash(git\ log:*),Bash(git\ diff:*),Bash(ls:*),Bash(wc:*)")
    claude_args+=(--max-turns 30)

    raw_output=$(claude "${claude_args[@]}" "$planner_prompt" 2>"$planner_log") || {
        log "$run_id" "PLANNER" "Claude Code planner invocation failed"
        log_error "Planner failed. See ${planner_log} for details."
        set_run_state "$run_dir" "failed"
        return 1
    }

    # Parse the planner output
    # Claude's --output-format json wraps the response; extract the result
    local plan_json=""

    # Try to extract from Claude's JSON envelope (result field)
    plan_json=$(echo "$raw_output" | jq -r '.result // empty' 2>/dev/null)

    if [[ -z "$plan_json" ]]; then
        # Maybe the raw output is already the plan JSON
        plan_json="$raw_output"
    fi

    # The result might be a string containing JSON -- try to parse it
    # If the result is a string with JSON embedded, extract it
    if ! echo "$plan_json" | jq '.tasks' >/dev/null 2>&1; then
        # Try to extract JSON from markdown code blocks (macOS compatible)
        local extracted
        extracted=$(echo "$plan_json" | awk '/^```json$/,/^```$/{if(!/^```/)print}' | head -1000)
        if [[ -n "$extracted" ]] && echo "$extracted" | jq '.tasks' >/dev/null 2>&1; then
            plan_json="$extracted"
        else
            # Try to extract any JSON object that has a "tasks" array
            extracted=$(echo "$raw_output" | jq -r 'if type == "object" and has("tasks") then . else empty end' 2>/dev/null)
            if [[ -n "$extracted" ]]; then
                plan_json="$extracted"
            else
                # Last resort: look for JSON in the text
                extracted=$(echo "$raw_output" | grep -Eo '\{[^{}]*"tasks"[^{}]*\}' | head -1)
                if [[ -n "$extracted" ]] && echo "$extracted" | jq '.tasks' >/dev/null 2>&1; then
                    plan_json="$extracted"
                else
                    log "$run_id" "PLANNER" "Failed to parse planner output as JSON"
                    log_error "Planner output was not valid JSON. Raw output saved to ${run_dir}/planner_raw_output.txt"
                    echo "$raw_output" > "${run_dir}/planner_raw_output.txt"
                    set_run_state "$run_dir" "failed"
                    return 1
                fi
            fi
        fi
    fi

    # Save the plan summary as markdown
    local plan_summary
    plan_summary=$(echo "$plan_json" | jq -r '.plan_summary // "No summary provided"')

    {
        echo "# Plan: ${goal}"
        echo ""
        echo "## Summary"
        echo "$plan_summary"
        echo ""
        echo "## Tasks"
        echo ""

        local task_count
        task_count=$(echo "$plan_json" | jq '.tasks | length')
        local idx=0
        while [[ $idx -lt $task_count ]]; do
            local task_title task_complexity task_deps
            task_title=$(echo "$plan_json" | jq -r ".tasks[$idx].title")
            task_complexity=$(echo "$plan_json" | jq -r ".tasks[$idx].estimated_complexity // \"medium\"")
            task_deps=$(echo "$plan_json" | jq -r ".tasks[$idx].depends_on // [] | join(\", \")")

            echo "### $((idx + 1)). ${task_title}"
            echo "- Complexity: ${task_complexity}"
            [[ -n "$task_deps" ]] && echo "- Depends on: ${task_deps}"
            echo "- $(echo "$plan_json" | jq -r ".tasks[$idx].description" | head -3)"
            echo ""
            idx=$((idx + 1))
        done
    } > "${run_dir}/plan.md"

    # Create task spec files from the JSON
    local created_count
    created_count=$(create_tasks_from_json "$run_dir" "$plan_json")

    log "$run_id" "PLANNER" "Created ${created_count} task specs"
    printf "${GREEN}Plan created:${NC} %s tasks\n" "$created_count"
    echo ""

    # Display the plan
    echo "─── Plan Summary ────────────────────────────────────────────"
    echo "$plan_summary"
    echo ""

    return 0
}
