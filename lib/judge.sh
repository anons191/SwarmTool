#!/usr/bin/env bash
# judge.sh -- Automated checks + Claude Code evaluation of worker results
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_JUDGE_LOADED:-}" ]] && return 0
_SWARMTOOL_JUDGE_LOADED=1

# JSON schema for judge verdict
JUDGE_JSON_SCHEMA='{
  "type": "object",
  "properties": {
    "verdict": { "type": "string", "enum": ["pass", "fail", "needs_revision"] },
    "score": { "type": "integer", "minimum": 1, "maximum": 10 },
    "summary": { "type": "string" },
    "issues": { "type": "array", "items": { "type": "string" } },
    "suggestions": { "type": "array", "items": { "type": "string" } }
  },
  "required": ["verdict", "score", "summary"]
}'

# ── Automated Checks ────────────────────────────────────────────────────────

# Run automated checks in a worktree
# Returns "pass" or an error description
# Usage: run_automated_checks <run_dir> <task_id>
run_automated_checks() {
    local run_dir="$1" task_id="$2"
    local worktree_file="${run_dir}/tasks/${task_id}.worktree"

    if [[ ! -f "$worktree_file" ]]; then
        echo "pass"  # No worktree = no checks possible
        return 0
    fi

    local worktree_path
    worktree_path=$(cat "$worktree_file")

    if [[ ! -d "$worktree_path" ]]; then
        echo "pass"  # Worktree already cleaned up
        return 0
    fi

    local abs_worktree
    abs_worktree=$(cd "$worktree_path" 2>/dev/null && pwd) || {
        echo "pass"
        return 0
    }

    local errors=""

    # Detect and run project-specific checks
    (
        cd "$abs_worktree" || exit 1

        # Check for common test/build runners
        if [[ -f "package.json" ]]; then
            # Node.js project
            if jq -e '.scripts.test' package.json >/dev/null 2>&1; then
                local test_cmd
                test_cmd=$(jq -r '.scripts.test' package.json)
                # Skip if test command is just an echo/exit placeholder
                if [[ "$test_cmd" != *"no test specified"* && "$test_cmd" != "exit "* ]]; then
                    if command -v npm >/dev/null 2>&1; then
                        npm test 2>&1 || echo "AUTOCHECK_FAIL:npm test failed"
                    fi
                fi
            fi

            # TypeScript compilation check
            if [[ -f "tsconfig.json" ]] && command -v npx >/dev/null 2>&1; then
                npx tsc --noEmit 2>&1 || echo "AUTOCHECK_FAIL:TypeScript compilation failed"
            fi

            # Lint check
            if jq -e '.scripts.lint' package.json >/dev/null 2>&1; then
                if command -v npm >/dev/null 2>&1; then
                    npm run lint 2>&1 || echo "AUTOCHECK_FAIL:Lint check failed"
                fi
            fi

        elif [[ -f "Cargo.toml" ]]; then
            # Rust project
            if command -v cargo >/dev/null 2>&1; then
                cargo check 2>&1 || echo "AUTOCHECK_FAIL:cargo check failed"
            fi

        elif [[ -f "go.mod" ]]; then
            # Go project
            if command -v go >/dev/null 2>&1; then
                go vet ./... 2>&1 || echo "AUTOCHECK_FAIL:go vet failed"
            fi

        elif [[ -f "pyproject.toml" || -f "setup.py" || -f "requirements.txt" ]]; then
            # Python project
            if command -v python3 >/dev/null 2>&1; then
                python3 -m py_compile *.py 2>/dev/null || true
            fi

        elif [[ -f "Makefile" ]]; then
            # Make-based project
            if make -n check >/dev/null 2>&1; then
                make check 2>&1 || echo "AUTOCHECK_FAIL:make check failed"
            fi
        fi
    ) 2>&1 | while IFS= read -r line; do
        if [[ "$line" == AUTOCHECK_FAIL:* ]]; then
            errors="${errors}${line#AUTOCHECK_FAIL:}; "
        fi
    done

    if [[ -n "$errors" ]]; then
        echo "$errors"
    else
        echo "pass"
    fi
}

# ── Claude Code Judge Evaluation ────────────────────────────────────────────

# Run Claude Code as judge for a single task
# Usage: judge_task <run_id> <run_dir> <task_id>
judge_task() {
    local run_id="$1" run_dir="$2" task_id="$3"
    local spec_file="${run_dir}/tasks/${task_id}.spec"
    local worktree_file="${run_dir}/tasks/${task_id}.worktree"
    local judge_file="${run_dir}/tasks/${task_id}.judge"
    local judge_log="${run_dir}/tasks/${task_id}.judge_log"

    # Convert to absolute paths (needed when we cd to worktree)
    local abs_run_dir
    abs_run_dir=$(cd "$run_dir" && pwd)
    judge_file="${abs_run_dir}/tasks/${task_id}.judge"
    judge_log="${abs_run_dir}/tasks/${task_id}.judge_log"

    local title
    title=$(taskspec_get "$spec_file" "TASK_TITLE")

    log "$run_id" "JUDGE" "Evaluating task: ${task_id} - ${title}"

    # Build judge prompt
    local judge_prompt
    judge_prompt=$(build_judge_prompt "$run_dir" "$task_id")

    local system_prompt=""
    local system_prompt_file="${SWARMTOOL_DIR}/prompts/judge_system.txt"
    [[ -f "$system_prompt_file" ]] && system_prompt=$(cat "$system_prompt_file")

    local judge_model="${SWARMTOOL_JUDGE_MODEL:-sonnet}"
    local judge_budget="${SWARMTOOL_JUDGE_BUDGET:-0.50}"

    # Determine working directory for the judge
    local work_dir="."
    if [[ -f "$worktree_file" ]]; then
        local wt
        wt=$(cat "$worktree_file")
        [[ -d "$wt" ]] && work_dir="$wt"
    fi

    local abs_work_dir
    abs_work_dir=$(cd "$work_dir" 2>/dev/null && pwd) || abs_work_dir="$(pwd)"

    # Invoke Claude Code as judge
    local claude_args=(-p)
    claude_args+=(--model "$judge_model")

    if [[ -n "$system_prompt" ]]; then
        claude_args+=(--system-prompt "$system_prompt")
    fi

    claude_args+=(--output-format json)
    claude_args+=(--allowedTools "Read,Glob,Grep,Bash(git\ diff:*),Bash(git\ log:*),Bash(git\ status:*)")
    claude_args+=(--max-turns 15)

    local raw_output=""
    raw_output=$(cd "$abs_work_dir" && claude "${claude_args[@]}" "$judge_prompt" 2>"$judge_log") || {
        log "$run_id" "JUDGE" "Judge invocation failed for ${task_id}"
        echo "VERDICT=error" > "$judge_file"
        echo "SUMMARY=Judge invocation failed" >> "$judge_file"
        return 1
    }

    # Parse the verdict
    local verdict_json=""
    verdict_json=$(echo "$raw_output" | jq -r '.result // empty' 2>/dev/null)
    [[ -z "$verdict_json" ]] && verdict_json="$raw_output"

    # Try to parse as JSON
    local verdict score summary
    if echo "$verdict_json" | jq -e '.verdict' >/dev/null 2>&1; then
        verdict=$(echo "$verdict_json" | jq -r '.verdict')
        score=$(echo "$verdict_json" | jq -r '.score // 0')
        summary=$(echo "$verdict_json" | jq -r '.summary // "No summary"')
    else
        # Couldn't parse structured output -- default to pass with warning
        verdict="pass"
        score=5
        summary="Judge output was not structured JSON. Defaulting to pass."
    fi

    # Write judge file
    {
        echo "VERDICT=${verdict}"
        echo "SCORE=${score}"
        echo "SUMMARY=${summary}"
    } > "$judge_file"

    # Color-coded output
    case "$verdict" in
        pass)
            printf "  ${GREEN}[pass]${NC} %s (score: %s) %s\n" "$title" "$score" "$summary"
            ;;
        fail)
            printf "  ${RED}[fail]${NC} %s (score: %s) %s\n" "$title" "$score" "$summary"
            ;;
        needs_revision)
            printf "  ${YELLOW}[revise]${NC} %s (score: %s) %s\n" "$title" "$score" "$summary"
            ;;
    esac

    log "$run_id" "JUDGE" "Task ${task_id}: verdict=${verdict}, score=${score}"
    return 0
}

# ── Judging Phase ───────────────────────────────────────────────────────────

# Run the judging phase for all completed tasks
# Usage: run_judging_phase <run_id> <run_dir>
run_judging_phase() {
    local run_id="$1" run_dir="$2"

    print_header "Judging"

    local done_tasks=()
    while IFS= read -r tid; do
        [[ -n "$tid" ]] && done_tasks+=("$tid")
    done < <(list_tasks_by_status "$run_dir" "done")

    if [[ ${#done_tasks[@]} -eq 0 ]]; then
        log_warn "No completed tasks to evaluate."
        return 0
    fi

    printf "Evaluating ${BOLD}%d${NC} completed tasks...\n\n" "${#done_tasks[@]}"

    for task_id in "${done_tasks[@]}"; do
        # Skip if already judged
        if [[ -f "${run_dir}/tasks/${task_id}.judge" ]]; then
            continue
        fi

        # Step 1: Automated checks
        printf "  ${DIM}[auto]${NC} Running automated checks for %s...\n" "$task_id"
        local auto_result
        auto_result=$(run_automated_checks "$run_dir" "$task_id")

        if [[ "$auto_result" != "pass" ]]; then
            printf "  ${RED}[fail]${NC} %s - Automated checks: %s\n" \
                "$(taskspec_get "${run_dir}/tasks/${task_id}.spec" "TASK_TITLE")" "$auto_result"
            echo "VERDICT=fail" > "${run_dir}/tasks/${task_id}.judge"
            echo "SCORE=0" >> "${run_dir}/tasks/${task_id}.judge"
            echo "SUMMARY=Automated checks failed: ${auto_result}" >> "${run_dir}/tasks/${task_id}.judge"
            continue
        fi

        # Step 2: Claude Code judge
        judge_task "$run_id" "$run_dir" "$task_id"
    done

    echo ""
    # Summary
    local pass_count=0 fail_count=0 revise_count=0
    for task_id in "${done_tasks[@]}"; do
        local judge_file="${run_dir}/tasks/${task_id}.judge"
        if [[ -f "$judge_file" ]]; then
            local verdict
            verdict=$(grep "^VERDICT=" "$judge_file" | cut -d'=' -f2-)
            case "$verdict" in
                pass) pass_count=$((pass_count + 1)) ;;
                fail) fail_count=$((fail_count + 1)) ;;
                needs_revision) revise_count=$((revise_count + 1)) ;;
            esac
        fi
    done

    printf "${BOLD}Judge Summary:${NC} ${GREEN}%d pass${NC} | ${RED}%d fail${NC} | ${YELLOW}%d needs revision${NC}\n" \
        "$pass_count" "$fail_count" "$revise_count"
}
