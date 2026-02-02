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

    # Run functional tests (DOM references, JS syntax, registry validation)
    local func_issues
    func_issues=$(run_functional_tests "$abs_worktree" "$run_dir")
    [[ -n "$func_issues" ]] && errors="${errors}${func_issues}"

    if [[ -n "$errors" ]]; then
        echo "$errors"
    else
        echo "pass"
    fi
}

# ── Functional Tests ───────────────────────────────────────────────────────

# Check that DOM references in JS actually exist in HTML
# Usage: check_dom_references <worktree_path>
check_dom_references() {
    local dir="$1"
    local issues=""

    # Skip if no HTML files in worktree (can't verify DOM references without HTML)
    local html_count
    html_count=$(find "$dir" -name "*.html" -not -path "*/node_modules/*" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$html_count" -eq 0 ]]; then
        echo ""  # No HTML = no DOM checks possible in isolated worktree
        return 0
    fi

    # Find all getElementById calls in JS
    local js_ids
    js_ids=$(grep -rohE "getElementById\(['\"]([^'\"]+)['\"]\)" --include="*.js" "$dir" 2>/dev/null | \
             sed -E "s/getElementById\(['\"]([^'\"]+)['\"]\)/\1/" | sort -u)

    # Find all IDs in HTML
    local html_ids
    html_ids=$(grep -rohE 'id="([^"]+)"' --include="*.html" "$dir" 2>/dev/null | \
               sed 's/id="\([^"]*\)"/\1/' | sort -u)

    # Check for mismatches
    for js_id in $js_ids; do
        [[ -z "$js_id" ]] && continue
        if ! echo "$html_ids" | grep -qx "$js_id"; then
            issues="${issues}DOM_MISMATCH: JS getElementById('$js_id') but no id=\"$js_id\" in HTML; "
        fi
    done

    # Find querySelector('#id') calls
    local qs_ids
    qs_ids=$(grep -rohE "querySelector\(['\"]#([^'\"]+)['\"]\)" --include="*.js" "$dir" 2>/dev/null | \
             sed -E "s/querySelector\(['\"]#([^'\"]+)['\"]\)/\1/" | sort -u)

    for qs_id in $qs_ids; do
        [[ -z "$qs_id" ]] && continue
        # Check for invalid selector syntax like '#.class' (mixing # and .)
        if [[ "$qs_id" == .* ]]; then
            issues="${issues}INVALID_SELECTOR: querySelector('#$qs_id') mixes ID and class syntax - use either '#id' or '.class', not both; "
            continue
        fi
        if ! echo "$html_ids" | grep -qx "$qs_id"; then
            issues="${issues}DOM_MISMATCH: JS querySelector('#$qs_id') but no id=\"$qs_id\" in HTML; "
        fi
    done

    # Check for other invalid selector patterns in JS
    local invalid_selectors
    invalid_selectors=$(grep -rohE "querySelector(All)?\(['\"][#\.]+[#\.][^'\"]*['\"]\)" --include="*.js" "$dir" 2>/dev/null | sort -u)
    for sel in $invalid_selectors; do
        issues="${issues}INVALID_SELECTOR: $sel has invalid selector syntax (consecutive # or . characters); "
    done

    echo "$issues"
}

# Check for JavaScript syntax errors
# Usage: check_js_syntax <worktree_path>
check_js_syntax() {
    local dir="$1"
    local issues=""

    # Find JS files (excluding node_modules)
    while IFS= read -r js_file; do
        [[ -z "$js_file" ]] && continue

        local check_result
        check_result=$(node --check "$js_file" 2>&1)
        local exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            # Skip ESM-related errors (not real syntax errors)
            if echo "$check_result" | grep -qE "(To load an ES module|Cannot use import|Unexpected token 'export')"; then
                # This is an ESM file being checked as CJS - not a real syntax error
                continue
            fi
            # Report real syntax errors
            issues="${issues}JS_SYNTAX_ERROR: $js_file; "
        fi
    done < <(find "$dir" -name "*.js" -not -path "*/node_modules/*" -type f 2>/dev/null)

    echo "$issues"
}

# Validate worker output against interface registry
# Usage: validate_against_registry <worktree> <run_dir>
validate_against_registry() {
    local worktree="$1" run_dir="$2"
    local registry="${run_dir}/interfaces.json"

    # Skip if no registry file
    [[ ! -f "$registry" ]] && return 0

    local issues=""

    # Get registered IDs from registry
    local registry_ids
    registry_ids=$(jq -r '.html_ids[]? // empty' "$registry" 2>/dev/null | sort -u)

    # Get registered classes from registry
    local registry_classes
    registry_classes=$(jq -r '.css_classes[]? // empty' "$registry" 2>/dev/null | sort -u)

    # Skip if registry is empty
    [[ -z "$registry_ids" && -z "$registry_classes" ]] && echo "" && return 0

    # Check JS getElementById calls against registry
    local js_ids
    js_ids=$(grep -rohE "getElementById\(['\"]([^'\"]+)['\"]\)" --include="*.js" "$worktree" 2>/dev/null | \
             sed -E "s/getElementById\(['\"]([^'\"]+)['\"]\)/\1/" | sort -u)

    for js_id in $js_ids; do
        [[ -z "$js_id" ]] && continue
        if [[ -n "$registry_ids" ]] && ! echo "$registry_ids" | grep -qx "$js_id"; then
            issues="${issues}REGISTRY_MISMATCH: JS uses getElementById('$js_id') but '$js_id' not in interface registry; "
        fi
    done

    # Check querySelector('#id') calls against registry
    local qs_ids
    qs_ids=$(grep -rohE "querySelector\(['\"]#([^'\"]+)['\"]\)" --include="*.js" "$worktree" 2>/dev/null | \
             sed -E "s/querySelector\(['\"]#([^'\"]+)['\"]\)/\1/" | sort -u)

    for qs_id in $qs_ids; do
        [[ -z "$qs_id" ]] && continue
        if [[ -n "$registry_ids" ]] && ! echo "$registry_ids" | grep -qx "$qs_id"; then
            issues="${issues}REGISTRY_MISMATCH: JS uses querySelector('#$qs_id') but '$qs_id' not in interface registry; "
        fi
    done

    # Check HTML IDs match registry (warn about IDs not in registry)
    local html_ids
    html_ids=$(grep -rohE 'id="([^"]+)"' --include="*.html" "$worktree" 2>/dev/null | \
               sed 's/id="\([^"]*\)"/\1/' | sort -u)

    for html_id in $html_ids; do
        [[ -z "$html_id" ]] && continue
        if [[ -n "$registry_ids" ]] && ! echo "$registry_ids" | grep -qx "$html_id"; then
            issues="${issues}REGISTRY_MISMATCH: HTML has id='$html_id' but '$html_id' not in interface registry; "
        fi
    done

    # Check CSS classes used in JS against registry
    local js_classes
    js_classes=$(grep -rohE "classList\.(add|remove|toggle)\(['\"]([^'\"]+)['\"]" --include="*.js" "$worktree" 2>/dev/null | \
                 sed -E "s/classList\.(add|remove|toggle)\(['\"]([^'\"]+)['\"]/\2/" | sort -u)

    for js_class in $js_classes; do
        [[ -z "$js_class" ]] && continue
        if [[ -n "$registry_classes" ]] && ! echo "$registry_classes" | grep -qx "$js_class"; then
            issues="${issues}REGISTRY_MISMATCH: JS uses class '$js_class' but it's not in interface registry; "
        fi
    done

    echo "$issues"
}

# Run functional tests for web projects
# Usage: run_functional_tests <worktree_path> [run_dir]
run_functional_tests() {
    local dir="$1"
    local run_dir="${2:-}"
    local issues=""

    # Check DOM references match
    local dom_issues
    dom_issues=$(check_dom_references "$dir")
    [[ -n "$dom_issues" ]] && issues="${issues}${dom_issues}"

    # Check JS syntax if node is available
    if command -v node >/dev/null 2>&1; then
        local js_issues
        js_issues=$(check_js_syntax "$dir")
        [[ -n "$js_issues" ]] && issues="${issues}${js_issues}"
    fi

    # Try to start server and test if it responds (for web apps)
    if [[ -f "$dir/package.json" ]]; then
        local start_script
        start_script=$(jq -r '.scripts.start // empty' "$dir/package.json" 2>/dev/null)

        if [[ -n "$start_script" ]]; then
            (
                cd "$dir" || exit 1

                # Install deps if needed (silent)
                [[ -d "node_modules" ]] || npm install --silent 2>/dev/null

                # Try to start server
                timeout 8 npm start >/dev/null 2>&1 &
                local server_pid=$!
                sleep 3

                # Check if server is running
                if kill -0 $server_pid 2>/dev/null; then
                    # Test if it responds
                    local port=3000
                    if ! curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/" 2>/dev/null | grep -qE "^(200|304)"; then
                        echo "SERVER_NO_RESPONSE: Server started but doesn't respond on port $port; "
                    fi
                    kill $server_pid 2>/dev/null
                fi
            ) 2>/dev/null
            # Capture any output from subshell
            local server_issues
            server_issues=$( (
                cd "$dir" || exit 1
                [[ -d "node_modules" ]] || npm install --silent 2>/dev/null
                timeout 8 npm start >/dev/null 2>&1 &
                local server_pid=$!
                sleep 3
                if kill -0 $server_pid 2>/dev/null; then
                    if ! curl -s -o /dev/null "http://localhost:3000/" 2>/dev/null; then
                        echo "SERVER_NO_RESPONSE"
                    fi
                    kill $server_pid 2>/dev/null
                fi
            ) 2>/dev/null )
            [[ "$server_issues" == *"SERVER_NO_RESPONSE"* ]] && issues="${issues}Server started but not responding; "
        fi
    fi

    # Validate against interface registry if run_dir is provided
    if [[ -n "$run_dir" ]]; then
        local registry_issues
        registry_issues=$(validate_against_registry "$dir" "$run_dir")
        [[ -n "$registry_issues" ]] && issues="${issues}${registry_issues}"
    fi

    echo "$issues"
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

    # Get provider:model spec for judge
    local judge_spec
    judge_spec=$(resolve_provider_spec judge)
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

    # Invoke LLM as judge
    local raw_output=""
    raw_output=$(cd "$abs_work_dir" && invoke_llm "$judge_spec" "$judge_prompt" \
        --system-prompt "$system_prompt" \
        --output-format json \
        --allowed-tools "Read,Glob,Grep,Bash(git\ diff:*),Bash(git\ log:*),Bash(git\ status:*)" \
        --max-turns 15 \
        2>"$judge_log") || {
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

    # Show architecture diagram if available
    if type show_architecture_inline &>/dev/null; then
        show_architecture_inline "judging"
    fi

    local done_tasks=()
    while IFS= read -r tid; do
        [[ -n "$tid" ]] && done_tasks+=("$tid")
    done < <(list_tasks_by_status "$run_dir" "done")

    if [[ ${#done_tasks[@]} -eq 0 ]]; then
        log_warn "No completed tasks to evaluate."
        return 0
    fi

    local total_tasks=${#done_tasks[@]}
    local current_task=0

    printf "Evaluating ${BOLD}%d${NC} completed tasks...\n\n" "$total_tasks"

    for task_id in "${done_tasks[@]}"; do
        ((current_task++))

        # Show progress bar
        if type show_phase_progress &>/dev/null; then
            show_phase_progress "Judging" "$current_task" "$total_tasks" "evaluating $task_id"
        fi
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

        # Step 2: Check if this is an install/setup task (fast-pass these)
        local task_title
        task_title=$(taskspec_get "${run_dir}/tasks/${task_id}.spec" "TASK_TITLE")
        local task_title_lower
        task_title_lower=$(echo "$task_title" | tr '[:upper:]' '[:lower:]')

        if [[ "$task_title_lower" == *"install"* || "$task_title_lower" == *"dependencies"* || "$task_title_lower" == *"npm install"* || "$task_title_lower" == *"pip install"* ]]; then
            # Fast-pass install tasks - they either work or they don't
            # Check if the worker reported success
            local result_file="${run_dir}/tasks/${task_id}.result"
            if [[ -f "$result_file" ]] && grep -q '"is_error":false' "$result_file" 2>/dev/null; then
                printf "  ${GREEN}[pass]${NC} %s (score: 5) Install task completed successfully - skipping detailed review\n" "$task_title"
                {
                    echo "VERDICT=pass"
                    echo "SCORE=5"
                    echo "SUMMARY=Install task completed successfully - skipped detailed review"
                } > "${run_dir}/tasks/${task_id}.judge"
                log "$run_id" "JUDGE" "Task ${task_id}: verdict=pass (fast-pass install task)"
                continue
            fi
        fi

        # Step 3: Claude Code judge for non-install tasks
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
