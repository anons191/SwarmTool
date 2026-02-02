#!/usr/bin/env bash
# interview.sh -- Interview phase for requirements gathering
# Asks clarifying questions before planning to improve task decomposition
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_INTERVIEW_LOADED:-}" ]] && return 0
_SWARMTOOL_INTERVIEW_LOADED=1

# ── Interview Phase ────────────────────────────────────────────────────────

# Run the interview phase to gather requirements
# Usage: run_interview_phase <run_id> <run_dir> <goal>
run_interview_phase() {
    local run_id="$1"
    local run_dir="$2"
    local goal="$3"

    log "$run_id" "INTERVIEW" "Starting interview for: $goal"
    printf "${BOLD}Interviewing...${NC} Gathering requirements.\n"
    echo ""

    # Get planner spec to determine provider
    local planner_spec
    planner_spec=$(resolve_provider_spec planner)
    local provider
    provider=$(get_provider "$planner_spec")

    local requirements_file="${run_dir}/requirements.md"

    if [[ "$provider" == "claude" ]]; then
        # Use Claude's native interview capability
        run_claude_interview "$run_id" "$run_dir" "$goal" "$requirements_file"
    else
        # Use prompt-based interview for other providers
        run_prompt_interview "$run_id" "$run_dir" "$goal" "$planner_spec" "$requirements_file"
    fi

    local exit_code=$?

    if [[ $exit_code -eq 0 && -f "$requirements_file" ]]; then
        log "$run_id" "INTERVIEW" "Requirements saved to requirements.md"
        printf "${GREEN}Requirements gathered.${NC}\n"
        echo ""

        # Display summary
        echo "─── Requirements Summary ────────────────────────────────────"
        grep -A 100 "## Summary" "$requirements_file" 2>/dev/null | head -10 || \
            head -20 "$requirements_file"
        echo ""
    else
        log "$run_id" "INTERVIEW" "Interview completed without requirements file"
    fi

    return $exit_code
}

# ── Claude Interview ───────────────────────────────────────────────────────

# Run interview using Claude's native capabilities
# Usage: run_claude_interview <run_id> <run_dir> <goal> <output_file>
run_claude_interview() {
    local run_id="$1"
    local run_dir="$2"
    local goal="$3"
    local output_file="$4"

    local interview_log="${run_dir}/interview.log"

    # Load interview system prompt
    local system_prompt=""
    local system_prompt_file="${SWARMTOOL_DIR}/prompts/interview_system.txt"
    [[ -f "$system_prompt_file" ]] && system_prompt=$(cat "$system_prompt_file")

    # Build the interview prompt
    local interview_prompt="Interview the user to understand their requirements for:

Goal: ${goal}

Ask 3-5 clarifying questions to understand:
1. Specific features and requirements
2. Technology preferences or constraints
3. What is NOT in scope
4. How they will know the project is successful

After gathering answers, create a requirements summary.

When you have enough information, write the requirements to a file called 'requirements.md' in the current directory."

    # Invoke Claude with interview tools
    local raw_output
    raw_output=$(invoke_llm "claude:opus" "$interview_prompt" \
        --system-prompt "$system_prompt" \
        --allowed-tools "AskUserQuestion,Write,Read" \
        --max-turns 15 \
        2>"$interview_log") || {
        log "$run_id" "INTERVIEW" "Claude interview failed"
        return 1
    }

    # Check if requirements.md was created
    if [[ -f "requirements.md" ]]; then
        mv "requirements.md" "$output_file"
    elif [[ -f "${run_dir}/requirements.md" ]]; then
        # Already in the right place
        :
    else
        # Claude didn't write the file, extract from output
        extract_requirements_from_output "$raw_output" "$output_file" "$goal"
    fi

    return 0
}

# ── Prompt-Based Interview ─────────────────────────────────────────────────

# Run interview using generated questions (for non-Claude providers)
# Usage: run_prompt_interview <run_id> <run_dir> <goal> <provider_spec> <output_file>
run_prompt_interview() {
    local run_id="$1"
    local run_dir="$2"
    local goal="$3"
    local provider_spec="$4"
    local output_file="$5"

    local interview_log="${run_dir}/interview.log"

    # Step 1: Generate questions
    printf "${DIM}Generating questions...${NC}\n"

    local questions_prompt="You are helping gather requirements for a software project.

Goal: ${goal}

Generate 3-5 clarifying questions to understand:
1. Specific features and requirements
2. Technology preferences or constraints
3. What is NOT in scope
4. Success criteria

Output valid JSON only:
{
  \"questions\": [
    {
      \"id\": 1,
      \"question\": \"What type of authentication do you need?\",
      \"examples\": \"JWT, OAuth, session-based, magic links\",
      \"context\": \"This affects security architecture\"
    }
  ]
}"

    local questions_json
    questions_json=$(invoke_llm "$provider_spec" "$questions_prompt" \
        --max-turns 1 \
        2>>"$interview_log")

    # Try to extract JSON from response
    local extracted_json
    extracted_json=$(echo "$questions_json" | jq '.' 2>/dev/null) || \
    extracted_json=$(echo "$questions_json" | grep -Eo '\{[^{}]*"questions"[^}]*\}' | head -1) || \
    extracted_json=$(echo "$questions_json" | awk '/```json/,/```/' | grep -v '```')

    if ! echo "$extracted_json" | jq '.questions' >/dev/null 2>&1; then
        log "$run_id" "INTERVIEW" "Failed to parse questions JSON, using fallback"
        # Fallback questions
        extracted_json='{
            "questions": [
                {"id": 1, "question": "What are the main features you need?", "examples": "list 2-3 key features"},
                {"id": 2, "question": "Are there any technology requirements or preferences?", "examples": "React, Node.js, Python, etc."},
                {"id": 3, "question": "What is explicitly NOT in scope for this project?", "examples": "mobile app, admin panel, etc."}
            ]
        }'
    fi

    # Step 2: Present questions and collect answers
    echo ""
    local answers=()
    local question_count
    question_count=$(echo "$extracted_json" | jq '.questions | length')

    for ((i=0; i<question_count; i++)); do
        local q examples
        q=$(echo "$extracted_json" | jq -r ".questions[$i].question")
        examples=$(echo "$extracted_json" | jq -r ".questions[$i].examples // empty")

        printf "${BOLD}Q%d:${NC} %s\n" "$((i+1))" "$q"
        [[ -n "$examples" ]] && printf "${DIM}(e.g., %s)${NC}\n" "$examples"
        printf "> "

        local answer
        read -r answer
        answers+=("$answer")
        echo ""
    done

    # Step 3: Build requirements document
    build_requirements_doc "$output_file" "$goal" "$extracted_json" "${answers[@]}"

    return 0
}

# ── Helper Functions ───────────────────────────────────────────────────────

# Build requirements.md from questions and answers
# Usage: build_requirements_doc <output_file> <goal> <questions_json> <answers...>
build_requirements_doc() {
    local output_file="$1"
    local goal="$2"
    local questions_json="$3"
    shift 3
    local answers=("$@")

    local question_count
    question_count=$(echo "$questions_json" | jq '.questions | length')

    {
        echo "# Requirements: ${goal}"
        echo ""
        echo "## Original Goal"
        echo "${goal}"
        echo ""
        echo "## Clarifying Questions & Answers"
        echo ""

        for ((i=0; i<question_count; i++)); do
            local q
            q=$(echo "$questions_json" | jq -r ".questions[$i].question")
            local a="${answers[$i]:-No answer provided}"

            echo "### Q$((i+1)): ${q}"
            echo "${a}"
            echo ""
        done

        echo "## Summary"
        echo ""
        echo "Based on the answers above, the project should:"
        echo ""

        # Generate summary bullets from answers
        for ((i=0; i<${#answers[@]}; i++)); do
            local a="${answers[$i]}"
            [[ -n "$a" && "$a" != "No answer provided" ]] && echo "- ${a}"
        done
        echo ""

    } > "$output_file"
}

# Extract requirements from Claude's text output if it didn't write a file
# Usage: extract_requirements_from_output <output> <output_file> <goal>
extract_requirements_from_output() {
    local output="$1"
    local output_file="$2"
    local goal="$3"

    # Try to find markdown content in the output
    local markdown_content
    markdown_content=$(echo "$output" | awk '/^# Requirements/,/^$/' | head -100)

    if [[ -n "$markdown_content" ]]; then
        echo "$markdown_content" > "$output_file"
    else
        # Create a basic requirements file from the goal
        {
            echo "# Requirements: ${goal}"
            echo ""
            echo "## Original Goal"
            echo "${goal}"
            echo ""
            echo "## Notes"
            echo "Interview was conducted but requirements were not captured in structured format."
            echo ""
            echo "## Raw Output"
            echo '```'
            echo "$output" | head -50
            echo '```'
        } > "$output_file"
    fi
}

# Check if a goal seems vague and might benefit from interview
# Usage: is_goal_vague <goal>
# Returns: 0 if vague, 1 if specific
is_goal_vague() {
    local goal="$1"
    local word_count
    word_count=$(echo "$goal" | wc -w | tr -d ' ')

    # Very short goals are likely vague
    if [[ $word_count -lt 5 ]]; then
        return 0
    fi

    # Check for vague keywords
    local vague_patterns="make it better|improve|fix|update|enhance|refactor|clean up|optimize"
    if echo "$goal" | grep -qiE "$vague_patterns"; then
        return 0
    fi

    # Seems specific enough
    return 1
}
