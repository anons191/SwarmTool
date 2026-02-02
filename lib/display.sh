#!/usr/bin/env bash
# display.sh -- Visual graphics and progress display for swarmtool
# Provides spinners, progress bars, dashboard, and architecture diagrams
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_DISPLAY_LOADED:-}" ]] && return 0
_SWARMTOOL_DISPLAY_LOADED=1

# ── Feature Detection ─────────────────────────────────────────────────────────
# Disable fancy display if not a terminal
USE_FANCY_DISPLAY=true
if [[ ! -t 1 ]]; then
    USE_FANCY_DISPLAY=false
fi

# ── Box Drawing Characters ────────────────────────────────────────────────────
BOX_TL='┌' BOX_TR='┐' BOX_BL='└' BOX_BR='┘'
BOX_H='─' BOX_V='│' BOX_CROSS='┼'
BOX_T_DOWN='┬' BOX_T_UP='┴' BOX_T_LEFT='┤' BOX_T_RIGHT='├'
BOX_DBL_TL='╔' BOX_DBL_TR='╗' BOX_DBL_BL='╚' BOX_DBL_BR='╝'
BOX_DBL_H='═' BOX_DBL_V='║' BOX_DBL_CROSS='╬'

# ── Unicode Symbols ───────────────────────────────────────────────────────────
SYM_CHECK='✓' SYM_CROSS='✗' SYM_DOT='●' SYM_CIRCLE='○'
SYM_ARROW='▶' SYM_BLOCK_FULL='█' SYM_BLOCK_EMPTY='░'
SYM_BLOCK_MED='▓' SYM_BLOCK_LIGHT='░'

# ── Spinner Frames ────────────────────────────────────────────────────────────
SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPINNER_FALLBACK=('|' '/' '-' '\')
SPINNER_PID=""

# Use fallback spinner if terminal doesn't support unicode well
if [[ "${TERM:-}" == "dumb" ]]; then
    SPINNER_FRAMES=("${SPINNER_FALLBACK[@]}")
fi

# ── Cursor Control ────────────────────────────────────────────────────────────
cursor_hide()    { [[ "$USE_FANCY_DISPLAY" == "true" ]] && printf '\033[?25l'; }
cursor_show()    { [[ "$USE_FANCY_DISPLAY" == "true" ]] && printf '\033[?25h'; }
cursor_up()      { [[ "$USE_FANCY_DISPLAY" == "true" ]] && printf '\033[%dA' "${1:-1}"; }
cursor_down()    { [[ "$USE_FANCY_DISPLAY" == "true" ]] && printf '\033[%dB' "${1:-1}"; }
cursor_save()    { [[ "$USE_FANCY_DISPLAY" == "true" ]] && printf '\033[s'; }
cursor_restore() { [[ "$USE_FANCY_DISPLAY" == "true" ]] && printf '\033[u'; }
clear_line()     { [[ "$USE_FANCY_DISPLAY" == "true" ]] && printf '\033[2K\r'; }
clear_to_end()   { [[ "$USE_FANCY_DISPLAY" == "true" ]] && printf '\033[J'; }

# ── Progress Bar ──────────────────────────────────────────────────────────────
# Usage: progress_bar <current> <total> [width]
# Example: progress_bar 3 10 30  => [█████████░░░░░░░░░░░░░░░░░░░░░] 30%
progress_bar() {
    local current=$1 total=$2 width=${3:-30}

    # Handle edge cases
    [[ $total -eq 0 ]] && total=1
    [[ $current -gt $total ]] && current=$total

    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    printf '['
    for ((i=0; i<filled; i++)); do printf '%s' "$SYM_BLOCK_FULL"; done
    for ((i=0; i<empty; i++)); do printf '%s' "$SYM_BLOCK_EMPTY"; done
    printf '] %3d%%' "$percent"
}

# ── Spinner Functions ─────────────────────────────────────────────────────────
# Usage: spinner_start "Loading..."
# Then call spinner_stop when done
spinner_start() {
    local message="$1"

    [[ "$USE_FANCY_DISPLAY" != "true" ]] && {
        printf '%s\n' "$message"
        return 0
    }

    cursor_hide

    # Run spinner in background subshell
    (
        local idx=0
        local frame_count=${#SPINNER_FRAMES[@]}
        while true; do
            printf '\r%s %b' "${SPINNER_FRAMES[$idx]}" "$message"
            idx=$(( (idx + 1) % frame_count ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!

    # Ensure spinner is killed on script exit
    trap 'spinner_stop' EXIT
}

spinner_stop() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
    fi
    clear_line
    cursor_show
}

# Update spinner message without restarting
spinner_update() {
    local message="$1"
    [[ "$USE_FANCY_DISPLAY" != "true" ]] && return 0

    # Kill existing spinner and start new one
    spinner_stop
    spinner_start "$message"
}

# ── Startup Banner ────────────────────────────────────────────────────────────
# Usage: show_banner
show_banner() {
    local version="${SWARMTOOL_VERSION:-0.1.0}"
    local title="swarmtool v${version} -- Multi-agent orchestration for Claude Code"
    local width=${#title}
    ((width += 4))  # padding

    if [[ "$USE_FANCY_DISPLAY" != "true" ]]; then
        printf '%s\n\n' "$title"
        return 0
    fi

    # Top border
    printf '%s' "$BOX_DBL_TL"
    for ((i=0; i<width; i++)); do printf '%s' "$BOX_DBL_H"; done
    printf '%s\n' "$BOX_DBL_TR"

    # Title
    printf '%s  %s  %s\n' "$BOX_DBL_V" "$title" "$BOX_DBL_V"

    # Bottom border
    printf '%s' "$BOX_DBL_BL"
    for ((i=0; i<width; i++)); do printf '%s' "$BOX_DBL_H"; done
    printf '%s\n' "$BOX_DBL_BR"
    echo ""
}

# ── Architecture Diagram ──────────────────────────────────────────────────────
# Usage: show_architecture [current_phase]
# Phases: planning, executing, judging, merging, complete
show_architecture() {
    local current="${1:-}"

    [[ "$USE_FANCY_DISPLAY" != "true" ]] && return 0

    # Color the current phase
    local c_planning="" c_executing="" c_judging="" c_merging="" c_complete=""
    local reset="$NC"

    case "$current" in
        planning)  c_planning="${CYAN}${BOLD}" ;;
        executing) c_executing="${CYAN}${BOLD}" ;;
        judging)   c_judging="${CYAN}${BOLD}" ;;
        merging)   c_merging="${CYAN}${BOLD}" ;;
        complete)  c_complete="${GREEN}${BOLD}" ;;
    esac

    cat <<DIAGRAM

                      ${BOX_TL}──────────${BOX_TR}
                      ${BOX_V}   Goal   ${BOX_V}
                      ${BOX_BL}────┬─────${BOX_BR}
                           │
                    ${c_planning}${BOX_TL}──────▼──────${BOX_TR}${reset}
                    ${c_planning}${BOX_V}   Planner   ${BOX_V}${reset}
                    ${c_planning}${BOX_BL}──────┬──────${BOX_BR}${reset}
                           │
         ${BOX_TL}─────────────┼─────────────${BOX_TR}
         │             │             │
   ${c_executing}${BOX_TL}─────▼─────${BOX_TR}${reset} ${c_executing}${BOX_TL}─────▼─────${BOX_TR}${reset} ${c_executing}${BOX_TL}─────▼─────${BOX_TR}${reset}
   ${c_executing}${BOX_V} Worker 1  ${BOX_V}${reset} ${c_executing}${BOX_V} Worker 2  ${BOX_V}${reset} ${c_executing}${BOX_V} Worker N  ${BOX_V}${reset}
   ${c_executing}${BOX_BL}─────┬─────${BOX_BR}${reset} ${c_executing}${BOX_BL}─────┬─────${BOX_BR}${reset} ${c_executing}${BOX_BL}─────┬─────${BOX_BR}${reset}
         │             │             │
         ${BOX_BL}─────────────┼─────────────${BOX_BR}
                           │
                    ${c_judging}${BOX_TL}──────▼──────${BOX_TR}${reset}
                    ${c_judging}${BOX_V}    Judge    ${BOX_V}${reset}
                    ${c_judging}${BOX_BL}──────┬──────${BOX_BR}${reset}
                           │
                    ${c_merging}${BOX_TL}──────▼──────${BOX_TR}${reset}
                    ${c_merging}${BOX_V}    Merge    ${BOX_V}${reset}
                    ${c_merging}${BOX_BL}──────┬──────${BOX_BR}${reset}
                           │
                      ${c_complete}${BOX_TL}────▼─────${BOX_TR}${reset}
                      ${c_complete}${BOX_V}  Result  ${BOX_V}${reset}
                      ${c_complete}${BOX_BL}──────────${BOX_BR}${reset}

DIAGRAM
}

# Compact inline architecture (for use during execution)
show_architecture_inline() {
    local current="${1:-}"

    [[ "$USE_FANCY_DISPLAY" != "true" ]] && return 0

    local phases=("planning" "executing" "judging" "merging" "complete")
    local labels=("Planner" "Workers" "Judge" "Merge" "Done")

    printf '%s' "$BOX_TL"
    for ((i=0; i<60; i++)); do printf '%s' "$BOX_H"; done
    printf '%s\n' "$BOX_TR"

    printf '%s  ' "$BOX_V"
    for i in "${!phases[@]}"; do
        local phase="${phases[$i]}"
        local label="${labels[$i]}"

        if [[ "$phase" == "$current" ]]; then
            printf '%b[%s]%b' "${CYAN}${BOLD}" "$label" "${NC}"
        else
            printf '%s' "$label"
        fi

        if [[ $i -lt $((${#phases[@]} - 1)) ]]; then
            printf ' → '
        fi
    done
    printf '  %s\n' "$BOX_V"

    printf '%s' "$BOX_BL"
    for ((i=0; i<60; i++)); do printf '%s' "$BOX_H"; done
    printf '%s\n' "$BOX_BR"
}

# ── Worker Dashboard ──────────────────────────────────────────────────────────
# Usage: draw_dashboard <run_dir> [total_elapsed_seconds]
# Draws a real-time worker status grid
draw_dashboard() {
    local run_dir="$1"
    local elapsed="${2:-0}"

    [[ "$USE_FANCY_DISPLAY" != "true" ]] && {
        display_progress "$run_dir"
        return 0
    }

    local tasks_dir="${run_dir}/tasks"
    [[ ! -d "$tasks_dir" ]] && return 1

    # Format elapsed time
    local elapsed_fmt
    elapsed_fmt=$(printf '%d:%02d' $((elapsed / 60)) $((elapsed % 60)))

    # Header
    local width=72
    printf '%s' "$BOX_TL"
    for ((i=0; i<width; i++)); do printf '%s' "$BOX_H"; done
    printf '%s\n' "$BOX_TR"

    printf '%s %-50s %18s %s\n' "$BOX_V" "${BOLD}Execution${NC}" "$elapsed_fmt" "$BOX_V"

    # Column headers
    printf '%s' "$BOX_T_RIGHT"
    for ((i=0; i<width; i++)); do printf '%s' "$BOX_H"; done
    printf '%s\n' "$BOX_T_LEFT"

    printf '%s  %-10s %s %-10s %s %-24s %s %-7s %s %-8s %s\n' \
        "$BOX_V" "ID" "$BOX_V" "Status" "$BOX_V" "Task" "$BOX_V" "Elapsed" "$BOX_V" "Progress" "$BOX_V"

    printf '%s' "$BOX_T_RIGHT"
    for ((i=0; i<width; i++)); do printf '%s' "$BOX_H"; done
    printf '%s\n' "$BOX_T_LEFT"

    # Task rows
    local done_count=0 running_count=0 pending_count=0 failed_count=0 total_count=0

    for spec_file in "$tasks_dir"/*.spec; do
        [[ ! -f "$spec_file" ]] && continue

        local task_id title status
        task_id=$(taskspec_get "$spec_file" "TASK_ID")
        title=$(taskspec_get "$spec_file" "TASK_TITLE")

        local status_file="${tasks_dir}/${task_id}.status"
        status="pending"
        [[ -f "$status_file" ]] && status=$(cat "$status_file")

        ((total_count++))

        # Status symbol and color
        local sym color
        case "$status" in
            done)    sym="$SYM_CHECK"; color="$GREEN"; ((done_count++)) ;;
            running) sym="$SYM_DOT"; color="$BLUE"; ((running_count++)) ;;
            failed)  sym="$SYM_CROSS"; color="$RED"; ((failed_count++)) ;;
            *)       sym="$SYM_CIRCLE"; color="$YELLOW"; ((pending_count++)) ;;
        esac

        # Truncate title if too long
        [[ ${#title} -gt 22 ]] && title="${title:0:19}..."

        # Elapsed time for this task (placeholder - would need task-level timing)
        local task_elapsed="-"

        # Progress indicator (simplified - full/empty based on status)
        local task_progress
        case "$status" in
            done)    task_progress="${SYM_BLOCK_FULL}${SYM_BLOCK_FULL}${SYM_BLOCK_FULL}${SYM_BLOCK_FULL}${SYM_BLOCK_FULL}${SYM_BLOCK_FULL}" ;;
            running) task_progress="${SYM_BLOCK_FULL}${SYM_BLOCK_FULL}${SYM_BLOCK_FULL}${SYM_BLOCK_EMPTY}${SYM_BLOCK_EMPTY}${SYM_BLOCK_EMPTY}" ;;
            failed)  task_progress="${SYM_BLOCK_FULL}${SYM_BLOCK_FULL}${SYM_BLOCK_FULL}${SYM_BLOCK_FULL}${SYM_BLOCK_EMPTY}${SYM_BLOCK_EMPTY}" ;;
            *)       task_progress="${SYM_BLOCK_EMPTY}${SYM_BLOCK_EMPTY}${SYM_BLOCK_EMPTY}${SYM_BLOCK_EMPTY}${SYM_BLOCK_EMPTY}${SYM_BLOCK_EMPTY}" ;;
        esac

        printf '%s  %-10s %s %s%-10s%s %s %-24s %s %7s %s %-8s %s\n' \
            "$BOX_V" "$task_id" \
            "$BOX_V" "$color" "$sym $status" "$NC" \
            "$BOX_V" "$title" \
            "$BOX_V" "$task_elapsed" \
            "$BOX_V" "$task_progress" "$BOX_V"
    done

    # Footer with overall progress
    printf '%s' "$BOX_T_RIGHT"
    for ((i=0; i<width; i++)); do printf '%s' "$BOX_H"; done
    printf '%s\n' "$BOX_T_LEFT"

    # Progress bar
    printf '%s ' "$BOX_V"
    progress_bar "$done_count" "$total_count" 30
    printf '  (%d done | %d run | %d pend | %d fail)' \
        "$done_count" "$running_count" "$pending_count" "$failed_count"
    printf ' %s\n' "$BOX_V"

    # Bottom border
    printf '%s' "$BOX_BL"
    for ((i=0; i<width; i++)); do printf '%s' "$BOX_H"; done
    printf '%s\n' "$BOX_BR"
}

# ── Phase Progress Display ────────────────────────────────────────────────────
# Usage: show_phase_progress <phase_name> <current> <total> [message]
show_phase_progress() {
    local phase="$1" current="$2" total="$3" message="${4:-}"

    if [[ "$USE_FANCY_DISPLAY" != "true" ]]; then
        printf '%s: %d/%d %s\n' "$phase" "$current" "$total" "$message"
        return 0
    fi

    clear_line
    printf '%s ' "$phase"
    progress_bar "$current" "$total" 35
    printf '  (%d/%d)' "$current" "$total"
    [[ -n "$message" ]] && printf '  %s' "$message"
    printf '\n'
}

# ── Task Status Line ──────────────────────────────────────────────────────────
# Usage: show_task_status <task_id> <title> <status> [verdict]
show_task_status() {
    local task_id="$1" title="$2" status="$3" verdict="${4:-}"

    local sym color
    case "$status" in
        done|pass)    sym="$SYM_CHECK"; color="$GREEN" ;;
        running)      sym="$SYM_DOT"; color="$BLUE" ;;
        evaluating)   sym="$SYM_DOT"; color="$CYAN" ;;
        failed|fail)  sym="$SYM_CROSS"; color="$RED" ;;
        *)            sym="$SYM_CIRCLE"; color="$YELLOW" ;;
    esac

    printf '  %s%s%s %-12s  %-30s' "$color" "$sym" "$NC" "$task_id" "$title"
    [[ -n "$verdict" ]] && printf '  %s' "$verdict"
    printf '\n'
}

# ── Completion Summary ────────────────────────────────────────────────────────
# Usage: show_completion_summary <run_id> <duration_seconds> <pass_count> <fail_count> <total_count>
show_completion_summary() {
    local run_id="$1" duration="$2" pass="$3" fail="$4" total="$5"

    local duration_fmt
    duration_fmt=$(printf '%dm %02ds' $((duration / 60)) $((duration % 60)))

    if [[ "$USE_FANCY_DISPLAY" != "true" ]]; then
        printf '\nRun Complete\n'
        printf '  Tasks:    %d total | %d pass | %d fail\n' "$total" "$pass" "$fail"
        printf '  Duration: %s\n' "$duration_fmt"
        printf '  Run ID:   %s\n' "$run_id"
        return 0
    fi

    local width=68

    echo ""
    # Top border
    printf '%s' "$BOX_DBL_TL"
    for ((i=0; i<width; i++)); do printf '%s' "$BOX_DBL_H"; done
    printf '%s\n' "$BOX_DBL_TR"

    # Title
    printf '%s%*s%s%*s%s\n' "$BOX_DBL_V" $(( (width - 12) / 2 )) "" "${BOLD}Run Complete${NC}" $(( (width - 12 + 1) / 2 )) "" "$BOX_DBL_V"

    # Separator
    printf '%s' "$BOX_DBL_V"
    for ((i=0; i<width; i++)); do printf '%s' "$BOX_H"; done
    printf '%s\n' "$BOX_DBL_V"

    # Stats
    printf '%s  Tasks:     %-10s %s %-10s %s %-10s %20s\n' \
        "$BOX_DBL_V" "${total} total" "${GREEN}${pass} pass${NC}" "${RED}${fail} fail${NC}" "" "$BOX_DBL_V"
    printf '%s  Duration:  %-52s %s\n' "$BOX_DBL_V" "$duration_fmt" "$BOX_DBL_V"
    printf '%s  Run ID:    %-52s %s\n' "$BOX_DBL_V" "$run_id" "$BOX_DBL_V"

    # Bottom border
    printf '%s' "$BOX_DBL_BL"
    for ((i=0; i<width; i++)); do printf '%s' "$BOX_DBL_H"; done
    printf '%s\n' "$BOX_DBL_BR"
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
# Ensure cursor is shown and spinner stopped on exit
display_cleanup() {
    spinner_stop
    cursor_show
}

trap display_cleanup EXIT
