#!/usr/bin/env bash
# conventions.sh -- Manage project conventions for consistent worker output
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_CONVENTIONS_LOADED:-}" ]] && return 0
_SWARMTOOL_CONVENTIONS_LOADED=1

# ── Default Conventions ─────────────────────────────────────────────────────

# Default conventions applied when no project-specific ones exist
DEFAULT_CONVENTIONS='{
  "moduleStyle": "esm",
  "naming": {
    "htmlIds": "kebab-case",
    "cssClasses": "kebab-case",
    "jsVariables": "camelCase",
    "jsFunctions": "camelCase",
    "apiFields": "snake_case",
    "dbColumns": "snake_case"
  },
  "formatting": {
    "indent": 2,
    "quotes": "single",
    "semicolons": true
  },
  "imports": {
    "style": "named",
    "extensions": true
  }
}'

# ── Detect Project Conventions ──────────────────────────────────────────────

# Detect conventions from existing project files
# Usage: detect_conventions <project_dir>
# Returns: JSON conventions object
detect_conventions() {
    local project_dir="${1:-.}"
    local conventions=""

    # Start with defaults
    local module_style="esm"
    local api_fields="snake_case"
    local html_ids="kebab-case"

    # Check for existing package.json
    if [[ -f "${project_dir}/package.json" ]]; then
        # Check if it's CommonJS or ESM
        if grep -q '"type":\s*"module"' "${project_dir}/package.json" 2>/dev/null; then
            module_style="esm"
        elif grep -q 'require(' "${project_dir}"/*.js 2>/dev/null; then
            module_style="commonjs"
        fi
    fi

    # Check for TypeScript
    local typescript="false"
    if [[ -f "${project_dir}/tsconfig.json" ]]; then
        typescript="true"
    fi

    # Check existing HTML files for ID naming convention
    if compgen -G "${project_dir}/**/*.html" > /dev/null 2>&1 || compgen -G "${project_dir}/*.html" > /dev/null 2>&1; then
        local html_file
        html_file=$(find "${project_dir}" -name "*.html" -type f 2>/dev/null | head -1)
        if [[ -n "$html_file" ]]; then
            if grep -qE 'id="[a-z]+-[a-z]+"' "$html_file" 2>/dev/null; then
                html_ids="kebab-case"
            elif grep -qE 'id="[a-z]+[A-Z][a-z]+"' "$html_file" 2>/dev/null; then
                html_ids="camelCase"
            fi
        fi
    fi

    # Check for Python project (uses snake_case everywhere)
    if [[ -f "${project_dir}/requirements.txt" ]] || [[ -f "${project_dir}/pyproject.toml" ]]; then
        api_fields="snake_case"
    fi

    # Check for Go project (uses camelCase/PascalCase)
    if [[ -f "${project_dir}/go.mod" ]]; then
        api_fields="camelCase"
    fi

    # Build conventions JSON
    cat <<EOF
{
  "moduleStyle": "${module_style}",
  "typescript": ${typescript},
  "naming": {
    "htmlIds": "${html_ids}",
    "cssClasses": "kebab-case",
    "jsVariables": "camelCase",
    "jsFunctions": "camelCase",
    "apiFields": "${api_fields}",
    "dbColumns": "snake_case"
  },
  "formatting": {
    "indent": 2,
    "quotes": "single",
    "semicolons": true
  },
  "imports": {
    "style": "named",
    "extensions": true
  }
}
EOF
}

# ── Generate Conventions File ───────────────────────────────────────────────

# Generate a conventions file for a run
# Usage: generate_conventions_file <run_dir> [project_dir]
generate_conventions_file() {
    local run_dir="$1"
    local project_dir="${2:-.}"
    local conventions_file="${run_dir}/conventions.json"

    # Detect from existing project or use defaults
    if [[ -d "$project_dir" ]] && [[ "$(ls -A "$project_dir" 2>/dev/null)" ]]; then
        detect_conventions "$project_dir" > "$conventions_file"
    else
        echo "$DEFAULT_CONVENTIONS" > "$conventions_file"
    fi

    echo "$conventions_file"
}

# ── Load Conventions ────────────────────────────────────────────────────────

# Load conventions for a run
# Usage: load_conventions <run_dir>
# Sets: CONVENTIONS_JSON global variable
load_conventions() {
    local run_dir="$1"
    local conventions_file="${run_dir}/conventions.json"

    if [[ -f "$conventions_file" ]]; then
        CONVENTIONS_JSON=$(cat "$conventions_file")
    else
        CONVENTIONS_JSON="$DEFAULT_CONVENTIONS"
    fi

    export CONVENTIONS_JSON
}

# ── Get Convention Value ────────────────────────────────────────────────────

# Get a specific convention value
# Usage: get_convention <key> [default]
# Example: get_convention "naming.apiFields" "snake_case"
get_convention() {
    local key="$1"
    local default="${2:-}"

    if [[ -z "${CONVENTIONS_JSON:-}" ]]; then
        echo "$default"
        return
    fi

    local value
    value=$(echo "$CONVENTIONS_JSON" | jq -r ".${key} // empty" 2>/dev/null)

    if [[ -n "$value" && "$value" != "null" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# ── Format Conventions for Prompt ───────────────────────────────────────────

# Format conventions as markdown for inclusion in prompts
# Usage: format_conventions_for_prompt
format_conventions_for_prompt() {
    if [[ -z "${CONVENTIONS_JSON:-}" ]]; then
        # Still provide strong defaults even without conventions file
        cat <<'EOF'
## Code Conventions (MANDATORY)

**Naming Rules:**
- HTML element IDs: kebab-case (e.g., `task-list`, `submit-btn`, `modal-overlay`)
- CSS classes: kebab-case (e.g., `btn-primary`, `card-header`, `task-card`)
- JavaScript variables/functions: camelCase (e.g., `taskList`, `handleSubmit`)
- API fields (JSON): snake_case (e.g., `user_id`, `created_at`, `due_date`)

**CRITICAL - Consistency Rules:**
- If you create `class="close-btn"` in HTML, CSS MUST use `.close-btn` (NOT `.close-button`)
- If you use `getElementById('task-form')`, HTML MUST have `id="task-form"`
- If backend returns `project_id`, frontend MUST access `data.project_id` (NOT `data.projectId`)

**Module System:** Use ESM (import/export), include .js extensions in imports.
EOF
        return
    fi

    local module_style api_fields html_ids
    module_style=$(get_convention "moduleStyle" "esm")
    api_fields=$(get_convention "naming.apiFields" "snake_case")
    html_ids=$(get_convention "naming.htmlIds" "kebab-case")

    cat <<EOF
## Code Conventions (MANDATORY)

**Module System:**
- Use ${module_style} style imports/exports
$(if [[ "$module_style" == "esm" ]]; then
    echo "- Use \`import\` and \`export\`, NOT \`require()\` and \`module.exports\`"
    echo "- Include file extensions in imports: \`import { foo } from './bar.js'\`"
else
    echo "- Use \`require()\` and \`module.exports\`, NOT \`import\`/\`export\`"
fi)

**Naming Rules:**
- HTML element IDs: ${html_ids} (e.g., \`task-list\`, \`submit-btn\`, \`modal-overlay\`)
- CSS classes: kebab-case (e.g., \`btn-primary\`, \`card-header\`, \`task-card\`)
- JavaScript variables/functions: camelCase (e.g., \`taskList\`, \`handleSubmit\`)
- API request/response fields: ${api_fields} (e.g., $(if [[ "$api_fields" == "snake_case" ]]; then echo "\`user_id\`, \`created_at\`"; else echo "\`userId\`, \`createdAt\`"; fi))
- Database columns: snake_case (e.g., \`user_id\`, \`created_at\`)

**CRITICAL - Consistency Rules:**
- If you create \`class="close-btn"\` in HTML, CSS MUST use \`.close-btn\` (NOT \`.close-button\`)
- If you use \`getElementById('task-form')\`, HTML MUST have \`id="task-form"\`
- If backend returns \`project_id\`, frontend MUST access \`data.project_id\` (NOT \`data.projectId\`)

These rules are NON-NEGOTIABLE. Mismatches break the application.
EOF
}

# ── Validate Conventions ────────────────────────────────────────────────────

# Check if a file follows conventions (basic validation)
# Usage: validate_file_conventions <file_path>
# Returns: 0 if valid, 1 if issues found (issues printed to stdout)
validate_file_conventions() {
    local file="$1"
    local issues=()

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    local ext="${file##*.}"
    local module_style
    module_style=$(get_convention "moduleStyle" "esm")

    # Check JavaScript/TypeScript files
    if [[ "$ext" == "js" || "$ext" == "ts" || "$ext" == "mjs" ]]; then
        if [[ "$module_style" == "esm" ]]; then
            if grep -q 'require(' "$file" 2>/dev/null; then
                issues+=("Uses require() but project uses ESM")
            fi
            if grep -q 'module\.exports' "$file" 2>/dev/null; then
                issues+=("Uses module.exports but project uses ESM")
            fi
        else
            if grep -q '^import ' "$file" 2>/dev/null; then
                issues+=("Uses import but project uses CommonJS")
            fi
            if grep -q '^export ' "$file" 2>/dev/null; then
                issues+=("Uses export but project uses CommonJS")
            fi
        fi
    fi

    if [[ ${#issues[@]} -gt 0 ]]; then
        for issue in "${issues[@]}"; do
            echo "${file}: ${issue}"
        done
        return 1
    fi

    return 0
}
