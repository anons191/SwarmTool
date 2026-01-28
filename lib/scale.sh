#!/usr/bin/env bash
# scale.sh -- Auto-scaling: detect system resources, compute max concurrent workers
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_SCALE_LOADED:-}" ]] && return 0
_SWARMTOOL_SCALE_LOADED=1

# ── Resource Detection ──────────────────────────────────────────────────────

# Detect number of CPU cores
detect_cpu_cores() {
    local cores=4  # fallback

    if [[ "$(uname)" == "Darwin" ]]; then
        cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    elif [[ -f /proc/cpuinfo ]]; then
        cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 4)
    fi

    echo "$cores"
}

# Detect available memory in GB
detect_memory_gb() {
    local mem_gb=8  # fallback

    if [[ "$(uname)" == "Darwin" ]]; then
        local mem_bytes
        mem_bytes=$(sysctl -n hw.memsize 2>/dev/null)
        if [[ -n "$mem_bytes" ]]; then
            mem_gb=$((mem_bytes / 1073741824))
        fi
    elif [[ -f /proc/meminfo ]]; then
        local mem_kb
        mem_kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')
        if [[ -n "$mem_kb" ]]; then
            mem_gb=$((mem_kb / 1048576))
        fi
    fi

    echo "$mem_gb"
}

# ── Max Workers Computation ─────────────────────────────────────────────────

# Compute the optimal number of concurrent workers
# Usage: detect_max_workers <task_count>
detect_max_workers() {
    local task_count="${1:-1}"

    # If user explicitly set max workers, respect it
    if [[ "${SWARMTOOL_MAX_WORKERS:-0}" -gt 0 ]]; then
        echo "$SWARMTOOL_MAX_WORKERS"
        return
    fi

    local cpu_cores mem_gb
    cpu_cores=$(detect_cpu_cores)
    mem_gb=$(detect_memory_gb)

    # CPU-based limit:
    # Claude Code workers are I/O bound (waiting on API), not CPU bound.
    # We can safely run 2x the number of cores.
    local cpu_limit=$((cpu_cores * 2))

    # Memory-based limit:
    # Each Claude Code subprocess (Node.js) uses ~200-500MB.
    # Reserve 4GB for the system, budget 500MB per worker.
    local mem_limit=$(( (mem_gb - 4) * 2 ))
    [[ "$mem_limit" -lt 1 ]] && mem_limit=1

    # API rate limit:
    # Claude API typically allows a bounded number of concurrent requests.
    local api_limit="${SWARMTOOL_API_CONCURRENCY:-5}"

    # Task count limit:
    # No point running more workers than tasks
    local task_limit="$task_count"

    # Take the minimum of all limits
    local max_workers="$cpu_limit"
    [[ "$mem_limit" -lt "$max_workers" ]] && max_workers="$mem_limit"
    [[ "$api_limit" -lt "$max_workers" ]] && max_workers="$api_limit"
    [[ "$task_limit" -lt "$max_workers" ]] && max_workers="$task_limit"

    # Floor at 1
    [[ "$max_workers" -lt 1 ]] && max_workers=1

    # Hard ceiling (safety valve)
    local hard_max="${SWARMTOOL_HARD_MAX_WORKERS:-10}"
    [[ "$max_workers" -gt "$hard_max" ]] && max_workers="$hard_max"

    echo "$max_workers"
}

# Display detected resources (for --verbose or debugging)
display_resources() {
    local cpu_cores mem_gb task_count max_workers
    cpu_cores=$(detect_cpu_cores)
    mem_gb=$(detect_memory_gb)
    task_count="${1:-1}"
    max_workers=$(detect_max_workers "$task_count")

    print_section "System Resources"
    echo "  CPU cores:       $cpu_cores"
    echo "  Memory:          ${mem_gb}GB"
    echo "  Task count:      $task_count"
    echo "  API concurrency: ${SWARMTOOL_API_CONCURRENCY:-5}"
    echo "  Max workers:     $max_workers"
}
