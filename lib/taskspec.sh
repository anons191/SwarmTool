#!/usr/bin/env bash
# taskspec.sh -- Task specification CRUD operations
# Flat-file format: KEY=value for single values, KEY<<ENDBLOCK...ENDBLOCK for multi-line
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_TASKSPEC_LOADED:-}" ]] && return 0
_SWARMTOOL_TASKSPEC_LOADED=1

# ── Read Operations ─────────────────────────────────────────────────────────

# Read a single-value field from a spec file
# Usage: taskspec_get <spec_file> <key>
taskspec_get() {
    local spec_file="$1" key="$2"
    grep "^${key}=" "$spec_file" 2>/dev/null | head -1 | cut -d'=' -f2-
}

# Read a multi-line block field from a spec file
# Usage: taskspec_get_block <spec_file> <key>
taskspec_get_block() {
    local spec_file="$1" key="$2"
    sed -n "/^${key}<<ENDBLOCK$/,/^ENDBLOCK$/{
        /^${key}<<ENDBLOCK$/d
        /^ENDBLOCK$/d
        p
    }" "$spec_file" 2>/dev/null
}

# ── Write Operations ────────────────────────────────────────────────────────

# Set a single-value field in a spec file (update if exists, append if not)
# Usage: taskspec_set <spec_file> <key> <value>
taskspec_set() {
    local spec_file="$1" key="$2" value="$3"

    if grep -q "^${key}=" "$spec_file" 2>/dev/null; then
        # Update existing field -- use a temp file for portability
        local tmp_file="${spec_file}.tmp"
        sed "s|^${key}=.*|${key}=${value}|" "$spec_file" > "$tmp_file"
        mv "$tmp_file" "$spec_file"
    else
        echo "${key}=${value}" >> "$spec_file"
    fi
}

# Set a multi-line block field (replace if exists, append if not)
# Usage: taskspec_set_block <spec_file> <key> <content>
taskspec_set_block() {
    local spec_file="$1" key="$2" content="$3"

    if grep -q "^${key}<<ENDBLOCK$" "$spec_file" 2>/dev/null; then
        # Remove old block and append new one
        local tmp_file="${spec_file}.tmp"
        sed "/^${key}<<ENDBLOCK$/,/^ENDBLOCK$/d" "$spec_file" > "$tmp_file"
        mv "$tmp_file" "$spec_file"
    fi

    # Append the block
    {
        echo "${key}<<ENDBLOCK"
        echo "$content"
        echo "ENDBLOCK"
    } >> "$spec_file"
}

# ── Task Creation ───────────────────────────────────────────────────────────

# Create a task spec file from parameters
# Usage: create_task_spec <run_dir> <task_id> <title> <description> <input_files> \
#                         <expected_output> <success_criteria> <boundaries> [depends_on] [priority]
create_task_spec() {
    local run_dir="$1"
    local task_id="$2"
    local title="$3"
    local description="$4"
    local input_files="$5"
    local expected_output="$6"
    local success_criteria="$7"
    local boundaries="$8"
    local depends_on="${9:-}"
    local priority="${10:-5}"

    local run_id
    run_id=$(basename "$run_dir")
    local spec_file="${run_dir}/tasks/${task_id}.spec"
    local branch_name="swarmtool/${run_id}/${task_id}"

    # Write the spec file
    cat > "$spec_file" <<EOF
TASK_ID=${task_id}
TASK_TITLE=${title}
TASK_STATUS=pending
TASK_PRIORITY=${priority}
TASK_BRANCH=${branch_name}
TASK_DEPENDS_ON=${depends_on}
TASK_RETRY_COUNT=0
TASK_MAX_RETRIES=${SWARMTOOL_WORKER_MAX_RETRIES}
TASK_WORKER_MODEL=${SWARMTOOL_WORKER_MODEL}
TASK_BUDGET_USD=${SWARMTOOL_WORKER_BUDGET}
EOF

    taskspec_set_block "$spec_file" "TASK_DESCRIPTION" "$description"
    taskspec_set_block "$spec_file" "TASK_INPUT_FILES" "$input_files"
    taskspec_set_block "$spec_file" "TASK_EXPECTED_OUTPUT" "$expected_output"
    taskspec_set_block "$spec_file" "TASK_SUCCESS_CRITERIA" "$success_criteria"
    taskspec_set_block "$spec_file" "TASK_BOUNDARIES" "$boundaries"

    # Initialize status file
    echo "pending" > "${run_dir}/tasks/${task_id}.status"

    echo "$spec_file"
}

# Create task specs from planner JSON output
# Usage: create_tasks_from_json <run_dir> <json_string>
create_tasks_from_json() {
    local run_dir="$1"
    local json_string="$2"

    local task_count
    task_count=$(echo "$json_string" | jq '.tasks | length')

    local i=0
    while [[ $i -lt $task_count ]]; do
        local task_json
        task_json=$(echo "$json_string" | jq -r ".tasks[$i]")

        local task_id title description input_files expected_output
        local success_criteria boundaries depends_on priority

        task_id=$(echo "$task_json" | jq -r '.id // empty')
        [[ -z "$task_id" ]] && task_id="task-$(printf '%03d' $((i + 1)))"

        title=$(echo "$task_json" | jq -r '.title // "Untitled task"')
        description=$(echo "$task_json" | jq -r '.description // ""')
        input_files=$(echo "$task_json" | jq -r '.input_files // [] | join("\n")')
        expected_output=$(echo "$task_json" | jq -r '.expected_output // ""')
        success_criteria=$(echo "$task_json" | jq -r '.success_criteria // ""')
        boundaries=$(echo "$task_json" | jq -r '.boundaries // ""')
        depends_on=$(echo "$task_json" | jq -r '.depends_on // [] | join(",")')
        priority=$(echo "$task_json" | jq -r '.priority // 5')

        create_task_spec "$run_dir" "$task_id" "$title" "$description" \
            "$input_files" "$expected_output" "$success_criteria" "$boundaries" \
            "$depends_on" "$priority"

        i=$((i + 1))
    done

    echo "$task_count"
}

# ── Task Queries ────────────────────────────────────────────────────────────

# Get the status of a task
# Usage: get_task_status <run_dir> <task_id>
get_task_status() {
    local run_dir="$1" task_id="$2"
    cat "${run_dir}/tasks/${task_id}.status" 2>/dev/null || echo "unknown"
}

# Set the status of a task
# Usage: set_task_status <run_dir> <task_id> <status>
set_task_status() {
    local run_dir="$1" task_id="$2" status="$3"
    echo "$status" > "${run_dir}/tasks/${task_id}.status"
}

# List all task IDs in a run
# Usage: list_task_ids <run_dir>
list_task_ids() {
    local run_dir="$1"
    for spec in "${run_dir}/tasks/"*.spec; do
        [[ -f "$spec" ]] || continue
        basename "$spec" .spec
    done
}

# List task IDs with a specific status
# Usage: list_tasks_by_status <run_dir> <status>
list_tasks_by_status() {
    local run_dir="$1" status="$2"
    for status_file in "${run_dir}/tasks/"*.status; do
        [[ -f "$status_file" ]] || continue
        if [[ "$(cat "$status_file")" == "$status" ]]; then
            basename "$status_file" .status
        fi
    done
}

# List tasks that are ready to execute (pending + all dependencies met)
# Usage: list_ready_tasks <run_dir>
list_ready_tasks() {
    local run_dir="$1"

    for task_id in $(list_tasks_by_status "$run_dir" "pending"); do
        local spec_file="${run_dir}/tasks/${task_id}.spec"
        local depends_on
        depends_on=$(taskspec_get "$spec_file" "TASK_DEPENDS_ON")

        if [[ -z "$depends_on" ]]; then
            echo "$task_id"
            continue
        fi

        # Check all dependencies are done
        local deps_met=true
        local IFS=','
        for dep in $depends_on; do
            dep=$(echo "$dep" | tr -d ' ')
            local dep_status
            dep_status=$(get_task_status "$run_dir" "$dep")
            if [[ "$dep_status" != "done" ]]; then
                deps_met=false
                break
            fi
        done
        unset IFS

        [[ "$deps_met" == "true" ]] && echo "$task_id"
    done
}

# Count tasks by status
# Usage: count_tasks <run_dir> [status]
count_tasks() {
    local run_dir="$1" status="${2:-}"
    local count=0

    if [[ -n "$status" ]]; then
        count=$(list_tasks_by_status "$run_dir" "$status" | wc -l | tr -d ' ')
    else
        for spec in "${run_dir}/tasks/"*.spec; do
            [[ -f "$spec" ]] && count=$((count + 1))
        done
    fi

    echo "$count"
}

# ── Task Display ────────────────────────────────────────────────────────────

# Display a summary of a single task
# Usage: display_task_summary <spec_file>
display_task_summary() {
    local spec_file="$1"
    local task_id title status priority depends_on

    task_id=$(taskspec_get "$spec_file" "TASK_ID")
    title=$(taskspec_get "$spec_file" "TASK_TITLE")
    priority=$(taskspec_get "$spec_file" "TASK_PRIORITY")
    depends_on=$(taskspec_get "$spec_file" "TASK_DEPENDS_ON")

    local status_file
    status_file="${spec_file%.spec}.status"
    status=$(cat "$status_file" 2>/dev/null || echo "pending")

    # Color the status
    local status_color="$NC"
    case "$status" in
        done)     status_color="$GREEN" ;;
        failed)   status_color="$RED" ;;
        running)  status_color="$BLUE" ;;
        pending)  status_color="$YELLOW" ;;
    esac

    local deps_str=""
    [[ -n "$depends_on" ]] && deps_str=" (depends: ${depends_on})"

    printf "  ${BOLD}%-12s${NC} ${status_color}[%-7s]${NC} P%s  %s%s\n" \
        "$task_id" "$status" "$priority" "$title" "$deps_str"
}

# Display all tasks in a run
# Usage: display_all_tasks <run_dir>
display_all_tasks() {
    local run_dir="$1"

    print_section "Tasks"
    for spec in "${run_dir}/tasks/"*.spec; do
        [[ -f "$spec" ]] || continue
        display_task_summary "$spec"
    done
    echo ""
}

# Display progress summary
# Usage: display_progress <run_dir>
display_progress() {
    local run_dir="$1"
    local total pending running done failed

    total=$(count_tasks "$run_dir")
    pending=$(count_tasks "$run_dir" "pending")
    running=$(count_tasks "$run_dir" "running")
    done=$(count_tasks "$run_dir" "done")
    failed=$(count_tasks "$run_dir" "failed")

    printf "${BOLD}Progress:${NC} "
    printf "${GREEN}%d done${NC} | " "$done"
    printf "${BLUE}%d running${NC} | " "$running"
    printf "${YELLOW}%d pending${NC} | " "$pending"
    printf "${RED}%d failed${NC} | " "$failed"
    printf "%d total\n" "$total"
}
