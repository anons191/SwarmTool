#!/usr/bin/env bash
# providers.sh -- LLM provider abstraction layer
# Enables swarmtool to use different LLM providers (Claude, OpenAI, Ollama, etc.)
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_PROVIDERS_LOADED:-}" ]] && return 0
_SWARMTOOL_PROVIDERS_LOADED=1

# ── Provider Configuration ─────────────────────────────────────────────────

# Default provider is Claude (for backwards compatibility)
: "${SWARMTOOL_DEFAULT_PROVIDER:=claude}"

# Provider-specific hosts
: "${OLLAMA_HOST:=http://localhost:11434}"
: "${LMSTUDIO_HOST:=http://localhost:1234}"
: "${OPENAI_BASE_URL:=https://api.openai.com/v1}"
: "${OPENROUTER_BASE_URL:=https://openrouter.ai/api/v1}"

# ── Provider Parsing ───────────────────────────────────────────────────────

# Parse a provider:model string and return the provider
# Usage: get_provider "claude:opus" -> "claude"
# Usage: get_provider "opus" -> "claude" (default provider)
get_provider() {
    local spec="$1"
    if [[ "$spec" == *:* ]]; then
        echo "${spec%%:*}"
    else
        echo "$SWARMTOOL_DEFAULT_PROVIDER"
    fi
}

# Parse a provider:model string and return the model
# Usage: get_model "claude:opus" -> "opus"
# Usage: get_model "opus" -> "opus"
get_model() {
    local spec="$1"
    if [[ "$spec" == *:* ]]; then
        echo "${spec#*:}"
    else
        echo "$spec"
    fi
}

# ── Provider Health Checks ─────────────────────────────────────────────────

# Check if a provider is available
# Usage: check_provider_health <provider>
# Returns: 0 if available, 1 if not
check_provider_health() {
    local provider="$1"

    case "$provider" in
        claude)
            # Check if claude CLI is available
            command -v claude >/dev/null 2>&1
            ;;
        openai)
            # Check if OPENAI_API_KEY is set
            [[ -n "${OPENAI_API_KEY:-}" ]]
            ;;
        openrouter)
            # Check if OPENROUTER_API_KEY is set
            [[ -n "${OPENROUTER_API_KEY:-}" ]]
            ;;
        ollama)
            # Check if Ollama is running
            curl -s --max-time 2 "${OLLAMA_HOST}/api/version" >/dev/null 2>&1
            ;;
        lmstudio)
            # Check if LM Studio is running
            curl -s --max-time 2 "${LMSTUDIO_HOST}/v1/models" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

# Get human-readable provider status
# Usage: get_provider_status <provider>
get_provider_status() {
    local provider="$1"

    if check_provider_health "$provider"; then
        echo "available"
    else
        case "$provider" in
            claude)
                echo "unavailable (claude CLI not found)"
                ;;
            openai)
                echo "unavailable (OPENAI_API_KEY not set)"
                ;;
            openrouter)
                echo "unavailable (OPENROUTER_API_KEY not set)"
                ;;
            ollama)
                echo "unavailable (Ollama not running at ${OLLAMA_HOST})"
                ;;
            lmstudio)
                echo "unavailable (LM Studio not running at ${LMSTUDIO_HOST})"
                ;;
            *)
                echo "unknown provider"
                ;;
        esac
    fi
}

# ── Main Invocation Function ───────────────────────────────────────────────

# Invoke an LLM with the given configuration
# Usage: invoke_llm <provider_model_spec> <prompt> [options...]
#
# Options (passed through to provider):
#   --system-prompt <prompt>   System prompt to use
#   --max-turns <n>            Maximum conversation turns
#   --allowed-tools <tools>    Comma-separated list of allowed tools (Claude only)
#   --output-format <format>   Output format (json, text)
#   --working-dir <dir>        Working directory for file operations
#
# Returns: LLM response to stdout
invoke_llm() {
    local spec="$1"
    local prompt="$2"
    shift 2

    local provider model
    provider=$(get_provider "$spec")
    model=$(get_model "$spec")

    # Check provider health
    if ! check_provider_health "$provider"; then
        echo "ERROR: Provider '$provider' is not available: $(get_provider_status "$provider")" >&2
        return 1
    fi

    # Route to provider-specific implementation
    case "$provider" in
        claude)
            invoke_claude "$model" "$prompt" "$@"
            ;;
        openai)
            invoke_openai "$model" "$prompt" "$@"
            ;;
        openrouter)
            invoke_openrouter "$model" "$prompt" "$@"
            ;;
        ollama)
            invoke_ollama "$model" "$prompt" "$@"
            ;;
        lmstudio)
            invoke_lmstudio "$model" "$prompt" "$@"
            ;;
        *)
            echo "ERROR: Unknown provider: $provider" >&2
            return 1
            ;;
    esac
}

# ── Claude Provider ────────────────────────────────────────────────────────

# Invoke Claude Code CLI
# Usage: invoke_claude <model> <prompt> [options...]
invoke_claude() {
    local model="$1"
    local prompt="$2"
    shift 2

    local system_prompt=""
    local max_turns=""
    local allowed_tools=""
    local output_format="json"
    local working_dir=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --system-prompt)
                system_prompt="$2"
                shift 2
                ;;
            --max-turns)
                max_turns="$2"
                shift 2
                ;;
            --allowed-tools)
                allowed_tools="$2"
                shift 2
                ;;
            --output-format)
                output_format="$2"
                shift 2
                ;;
            --working-dir)
                working_dir="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Build Claude CLI arguments
    local claude_args=(-p)
    claude_args+=(--model "$model")

    [[ -n "$system_prompt" ]] && claude_args+=(--system-prompt "$system_prompt")
    [[ -n "$output_format" ]] && claude_args+=(--output-format "$output_format")
    [[ -n "$allowed_tools" ]] && claude_args+=(--allowedTools "$allowed_tools")
    [[ -n "$max_turns" ]] && claude_args+=(--max-turns "$max_turns")

    # Execute in working directory if specified
    if [[ -n "$working_dir" ]]; then
        (cd "$working_dir" && claude "${claude_args[@]}" "$prompt")
    else
        claude "${claude_args[@]}" "$prompt"
    fi
}

# ── OpenAI Provider (placeholder for Phase 2) ──────────────────────────────

# Invoke OpenAI API
# Usage: invoke_openai <model> <prompt> [options...]
invoke_openai() {
    local model="$1"
    local prompt="$2"
    shift 2

    local system_prompt=""
    local max_tokens=4096
    local base_url="${OPENAI_BASE_URL}"
    local api_key="${OPENAI_API_KEY:-}"

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --system-prompt)
                system_prompt="$2"
                shift 2
                ;;
            --max-turns)
                # Rough conversion: turns -> tokens
                max_tokens=$((${2} * 2000))
                shift 2
                ;;
            --base-url)
                base_url="$2"
                shift 2
                ;;
            --api-key)
                api_key="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Build messages array
    local messages="[]"
    if [[ -n "$system_prompt" ]]; then
        messages=$(jq -n --arg s "$system_prompt" '[{role:"system",content:$s}]')
    fi
    messages=$(echo "$messages" | jq --arg p "$prompt" '. + [{role:"user",content:$p}]')

    # Make API request
    local response
    response=$(curl -s "${base_url}/chat/completions" \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg model "$model" \
            --argjson messages "$messages" \
            --argjson max_tokens "$max_tokens" \
            '{model:$model, messages:$messages, max_tokens:$max_tokens}'
        )")

    # Extract content from response
    echo "$response" | jq -r '.choices[0].message.content // .error.message // "Error: No response"'
}

# ── OpenRouter Provider (placeholder for Phase 2) ──────────────────────────

# Invoke OpenRouter API (OpenAI-compatible)
# Usage: invoke_openrouter <model> <prompt> [options...]
invoke_openrouter() {
    local model="$1"
    shift

    # OpenRouter uses OpenAI-compatible API
    OPENAI_BASE_URL="${OPENROUTER_BASE_URL}" \
    OPENAI_API_KEY="${OPENROUTER_API_KEY:-}" \
    invoke_openai "$model" "$@"
}

# ── Ollama Provider (placeholder for Phase 3) ──────────────────────────────

# Invoke Ollama API
# Usage: invoke_ollama <model> <prompt> [options...]
invoke_ollama() {
    local model="$1"
    local prompt="$2"
    shift 2

    local system_prompt=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --system-prompt)
                system_prompt="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Build full prompt with system message
    local full_prompt="$prompt"
    if [[ -n "$system_prompt" ]]; then
        full_prompt="System: ${system_prompt}

User: ${prompt}"
    fi

    # Make API request
    local response
    response=$(curl -s "${OLLAMA_HOST}/api/generate" \
        -d "$(jq -n \
            --arg model "$model" \
            --arg prompt "$full_prompt" \
            '{model:$model, prompt:$prompt, stream:false}'
        )")

    # Extract response
    echo "$response" | jq -r '.response // .error // "Error: No response"'
}

# ── LM Studio Provider (placeholder for Phase 3) ───────────────────────────

# Invoke LM Studio API (OpenAI-compatible)
# Usage: invoke_lmstudio <model> <prompt> [options...]
invoke_lmstudio() {
    # LM Studio exposes OpenAI-compatible API
    OPENAI_BASE_URL="${LMSTUDIO_HOST}/v1" \
    OPENAI_API_KEY="lm-studio" \
    invoke_openai "$@"
}

# ── Utility Functions ──────────────────────────────────────────────────────

# List available providers and their status
list_providers() {
    echo "Available LLM Providers:"
    echo ""
    for provider in claude openai openrouter ollama lmstudio; do
        local status
        status=$(get_provider_status "$provider")
        if [[ "$status" == "available" ]]; then
            printf "  ${GREEN}●${NC} %-12s %s\n" "$provider" "$status"
        else
            printf "  ${RED}○${NC} %-12s %s\n" "$provider" "$status"
        fi
    done
}

# Get context window size for a model (approximate)
# Usage: get_context_window <provider> <model>
get_context_window() {
    local provider="$1"
    local model="$2"

    case "$provider" in
        claude)
            # All Claude 3+ models have 200K context
            echo "200000"
            ;;
        openai)
            case "$model" in
                gpt-4o*|gpt-4-turbo*) echo "128000" ;;
                gpt-4*) echo "8192" ;;
                gpt-3.5*) echo "16385" ;;
                *) echo "8192" ;;
            esac
            ;;
        ollama)
            # Varies by model - default to conservative estimate
            case "$model" in
                *qwen2*) echo "32768" ;;
                *llama3*70b*) echo "8192" ;;
                *llama3*) echo "8192" ;;
                *codellama*) echo "16384" ;;
                *mistral*) echo "32768" ;;
                *) echo "4096" ;;
            esac
            ;;
        openrouter)
            # Depends on the underlying model
            case "$model" in
                anthropic/*) echo "200000" ;;
                openai/gpt-4o*) echo "128000" ;;
                meta-llama/*70b*) echo "8192" ;;
                *) echo "8192" ;;
            esac
            ;;
        *)
            echo "4096"
            ;;
    esac
}
