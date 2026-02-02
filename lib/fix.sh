#!/usr/bin/env bash
# fix.sh -- Integration fixer for swarmtool
# Analyzes merged code for integration issues and fixes them automatically
# Sourced by swarmtool main entry point. Do not execute directly.

[[ -n "${_SWARMTOOL_FIX_LOADED:-}" ]] && return 0
_SWARMTOOL_FIX_LOADED=1

# ── Configuration ───────────────────────────────────────────────────────────

SWARMTOOL_FIX_MAX_ATTEMPTS="${SWARMTOOL_FIX_MAX_ATTEMPTS:-3}"
SWARMTOOL_FIX_BUDGET="${SWARMTOOL_FIX_BUDGET:-5.00}"

# ── Project Detection ───────────────────────────────────────────────────────

# Detect project type and return build/test commands
# Usage: detect_project_type [dir]
# Returns: JSON with project info
detect_project_type() {
    local dir="${1:-.}"
    local project_type="unknown"
    local build_cmd=""
    local test_cmd=""
    local start_cmd=""
    local install_cmd=""

    if [[ -f "${dir}/package.json" ]]; then
        project_type="node"
        install_cmd="npm install"

        # Check for TypeScript
        if [[ -f "${dir}/tsconfig.json" ]]; then
            build_cmd="npx tsc --noEmit"
        fi

        # Check for build script
        if jq -e '.scripts.build' "${dir}/package.json" >/dev/null 2>&1; then
            build_cmd="npm run build"
        fi

        # Check for test script
        if jq -e '.scripts.test' "${dir}/package.json" >/dev/null 2>&1; then
            local test_script
            test_script=$(jq -r '.scripts.test' "${dir}/package.json")
            if [[ "$test_script" != *"no test specified"* ]]; then
                test_cmd="npm test"
            fi
        fi

        # Check for start script
        if jq -e '.scripts.start' "${dir}/package.json" >/dev/null 2>&1; then
            start_cmd="npm start"
        elif [[ -f "${dir}/server.js" ]]; then
            start_cmd="node server.js"
        elif [[ -f "${dir}/index.js" ]]; then
            start_cmd="node index.js"
        fi

    elif [[ -f "${dir}/go.mod" ]]; then
        project_type="go"
        build_cmd="go build ./..."
        test_cmd="go test ./..."

    elif [[ -f "${dir}/Cargo.toml" ]]; then
        project_type="rust"
        build_cmd="cargo check"
        test_cmd="cargo test"

    elif [[ -f "${dir}/requirements.txt" ]] || [[ -f "${dir}/pyproject.toml" ]]; then
        project_type="python"
        install_cmd="pip install -r requirements.txt 2>/dev/null || pip install -e . 2>/dev/null || true"

        if [[ -f "${dir}/pytest.ini" ]] || [[ -d "${dir}/tests" ]]; then
            test_cmd="python -m pytest"
        fi
    fi

    cat <<EOF
{
  "type": "${project_type}",
  "install": "${install_cmd}",
  "build": "${build_cmd}",
  "test": "${test_cmd}",
  "start": "${start_cmd}"
}
EOF
}

# ── Run Project Validation ──────────────────────────────────────────────────

# Try to build/validate the project and capture errors
# Usage: validate_project [dir]
# Returns: JSON with validation results
validate_project() {
    local dir="${1:-.}"
    local project_info
    project_info=$(detect_project_type "$dir")

    local project_type install_cmd build_cmd test_cmd
    project_type=$(echo "$project_info" | jq -r '.type')
    install_cmd=$(echo "$project_info" | jq -r '.install // empty')
    build_cmd=$(echo "$project_info" | jq -r '.build // empty')
    test_cmd=$(echo "$project_info" | jq -r '.test // empty')

    local errors=""
    local warnings=""
    local success=true

    (
        cd "$dir" || exit 1

        # Step 1: Install dependencies if needed
        if [[ -n "$install_cmd" ]]; then
            local install_output
            install_output=$(eval "$install_cmd" 2>&1) || {
                echo "INSTALL_ERROR:${install_output}"
            }
        fi

        # Step 2: Run build/compile check
        if [[ -n "$build_cmd" ]]; then
            local build_output
            build_output=$(eval "$build_cmd" 2>&1) || {
                echo "BUILD_ERROR:${build_output}"
            }
        fi

        # Step 3: Run syntax/import checks for Node.js
        if [[ "$project_type" == "node" ]]; then
            # Try to import main entry point
            local main_file=""
            if [[ -f "server.js" ]]; then
                main_file="server.js"
            elif [[ -f "index.js" ]]; then
                main_file="index.js"
            elif [[ -f "src/index.js" ]]; then
                main_file="src/index.js"
            fi

            if [[ -n "$main_file" ]]; then
                local import_output
                import_output=$(node --check "$main_file" 2>&1) || {
                    echo "SYNTAX_ERROR:${import_output}"
                }
            fi
        fi
    ) 2>&1 | while IFS= read -r line; do
        case "$line" in
            INSTALL_ERROR:*)
                errors="${errors}Install failed: ${line#INSTALL_ERROR:}\n"
                success=false
                ;;
            BUILD_ERROR:*)
                errors="${errors}Build failed: ${line#BUILD_ERROR:}\n"
                success=false
                ;;
            SYNTAX_ERROR:*)
                errors="${errors}Syntax/Import error: ${line#SYNTAX_ERROR:}\n"
                success=false
                ;;
        esac
    done

    # Capture the output
    local validation_output
    validation_output=$(
        cd "$dir" || exit 1

        if [[ -n "$install_cmd" ]]; then
            eval "$install_cmd" 2>&1 || true
        fi

        if [[ -n "$build_cmd" ]]; then
            eval "$build_cmd" 2>&1
        fi
    ) 2>&1

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        cat <<EOF
{
  "success": false,
  "project_type": "${project_type}",
  "errors": $(echo "$validation_output" | jq -Rs .),
  "exit_code": ${exit_code}
}
EOF
    else
        cat <<EOF
{
  "success": true,
  "project_type": "${project_type}",
  "errors": null,
  "exit_code": 0
}
EOF
    fi
}

# ── Analyze Integration Issues ──────────────────────────────────────────────

# Analyze the project for common integration issues
# Usage: analyze_integration_issues [dir]
analyze_integration_issues() {
    local dir="${1:-.}"
    local issues=()

    (
        cd "$dir" || exit 1

        # Check for module style mismatches
        if [[ -f "package.json" ]]; then
            local is_esm=false
            if grep -q '"type":\s*"module"' package.json 2>/dev/null; then
                is_esm=true
            fi

            # Find files using wrong module style
            if [[ "$is_esm" == "true" ]]; then
                local commonjs_files
                commonjs_files=$(grep -rl "require(" --include="*.js" . 2>/dev/null | grep -v node_modules || true)
                if [[ -n "$commonjs_files" ]]; then
                    echo "MODULE_MISMATCH: ESM project but these files use require(): $commonjs_files"
                fi
            else
                local esm_files
                esm_files=$(grep -rl "^import " --include="*.js" . 2>/dev/null | grep -v node_modules || true)
                if [[ -n "$esm_files" ]]; then
                    echo "MODULE_MISMATCH: CommonJS project but these files use import: $esm_files"
                fi
            fi
        fi

        # Check for HTML ID vs JavaScript ID mismatches
        if compgen -G "*.html" > /dev/null 2>&1 || compgen -G "**/*.html" > /dev/null 2>&1; then
            local html_ids js_ids
            html_ids=$(grep -oh 'id="[^"]*"' *.html **/*.html 2>/dev/null | sed 's/id="//g; s/"//g' | sort -u || true)
            js_ids=$(grep -oh "getElementById('[^']*')" *.js **/*.js 2>/dev/null | sed "s/getElementById('//g; s/')//g" | sort -u || true)
            js_ids+=$(grep -oh 'getElementById("[^"]*")' *.js **/*.js 2>/dev/null | sed 's/getElementById("//g; s/")//g' | sort -u || true)

            # Find IDs referenced in JS but not in HTML
            for js_id in $js_ids; do
                if [[ -n "$js_id" ]] && ! echo "$html_ids" | grep -qx "$js_id"; then
                    echo "ID_MISMATCH: JavaScript references '$js_id' but it doesn't exist in HTML"
                fi
            done
        fi

        # Check for API field name mismatches (snake_case vs camelCase)
        if [[ -d "routes" ]] || compgen -G "**/routes/*.js" > /dev/null 2>&1; then
            # Check if backend uses snake_case
            local backend_snake=false
            if grep -rq "project_id\|user_id\|created_at\|updated_at" routes/ 2>/dev/null; then
                backend_snake=true
            fi

            # Check if frontend uses camelCase for same fields
            if [[ "$backend_snake" == "true" ]] && [[ -d "public/js" ]]; then
                if grep -rq "projectId\|userId\|createdAt\|updatedAt" public/js/ 2>/dev/null; then
                    echo "FIELD_MISMATCH: Backend uses snake_case (project_id) but frontend uses camelCase (projectId)"
                fi
            fi
        fi

        # Check for missing imports/exports
        if [[ -f "package.json" ]] && grep -q '"type":\s*"module"' package.json 2>/dev/null; then
            # Check for imports without .js extension
            local missing_ext
            missing_ext=$(grep -roh "from '[^']*'" --include="*.js" . 2>/dev/null | grep -v node_modules | grep -v "\.js'" | grep "\./" || true)
            if [[ -n "$missing_ext" ]]; then
                echo "IMPORT_EXTENSION: ESM imports missing .js extension: $missing_ext"
            fi
        fi

        # NEW: Check for CSS class mismatches
        # Extract classes used in JS via classList.add/remove/toggle and querySelector
        local js_classes=""
        js_classes=$(grep -rohE "classList\.(add|remove|toggle)\(['\"]([^'\"]+)['\"]" --include="*.js" . 2>/dev/null | \
                     grep -v node_modules | \
                     sed -E "s/classList\.(add|remove|toggle)\(['\"]([^'\"]+)['\"]/\2/" | \
                     sort -u || true)

        # Extract classes from querySelector('.class')
        local qs_classes
        qs_classes=$(grep -rohE "querySelector(All)?\(['\"]\.([^'\"#\[]+)['\"]" --include="*.js" . 2>/dev/null | \
                     grep -v node_modules | \
                     sed -E "s/querySelector(All)?\(['\"]\.([^'\"]+)['\"]/\2/" | \
                     cut -d' ' -f1 | cut -d'.' -f1 | \
                     sort -u || true)

        # Extract classes defined in CSS files
        local css_classes
        css_classes=$(grep -rohE "\.[a-zA-Z][a-zA-Z0-9_-]*" --include="*.css" . 2>/dev/null | \
                      grep -v node_modules | \
                      sed 's/^\.//' | sort -u || true)

        # Also check classes used in HTML
        local html_classes
        html_classes=$(grep -rohE 'class="[^"]*"' --include="*.html" . 2>/dev/null | \
                       sed 's/class="//g; s/"//g' | tr ' ' '\n' | sort -u || true)

        # Find JS classes not in CSS or HTML
        for js_class in $js_classes $qs_classes; do
            [[ -z "$js_class" ]] && continue
            [[ "$js_class" == *"{"* ]] && continue  # Skip template literals
            if ! echo "$css_classes" | grep -qx "$js_class" 2>/dev/null; then
                if ! echo "$html_classes" | grep -qx "$js_class" 2>/dev/null; then
                    echo "CSS_MISMATCH: JS uses class '$js_class' but it's not defined in CSS or HTML"
                fi
            fi
        done

        # NEW: Check querySelector('#id') references
        local qs_ids
        qs_ids=$(grep -rohE "querySelector(All)?\(['\"]#([^'\"]+)['\"]" --include="*.js" . 2>/dev/null | \
                 grep -v node_modules | \
                 sed -E "s/querySelector(All)?\(['\"]#([^'\"]+)['\"]/\2/" | \
                 sort -u || true)

        for qs_id in $qs_ids; do
            [[ -z "$qs_id" ]] && continue
            if [[ -n "$html_ids" ]] && ! echo "$html_ids" | grep -qx "$qs_id" 2>/dev/null; then
                echo "SELECTOR_MISMATCH: JS querySelector('#$qs_id') but no id=\"$qs_id\" in HTML"
            fi
        done

        # NEW: Check for inline style that might conflict with CSS classes
        local inline_style_elements
        inline_style_elements=$(grep -rohE '<[^>]+style="[^"]*"[^>]*class="[^"]*"' --include="*.html" . 2>/dev/null | wc -l | tr -d ' \n' || echo 0)
        if [[ "$inline_style_elements" -gt 5 ]]; then
            echo "STYLE_WARNING: Found $inline_style_elements elements with both inline styles and classes (potential conflicts)"
        fi

        # NEW: Check for runtime issues - try to start server and test
        if [[ -f "package.json" ]]; then
            local start_cmd
            start_cmd=$(jq -r '.scripts.start // empty' package.json 2>/dev/null)

            if [[ -n "$start_cmd" ]]; then
                # Install deps silently if needed
                [[ -d "node_modules" ]] || npm install --silent 2>/dev/null || true

                # Try to start server briefly
                timeout 5 npm start >/dev/null 2>&1 &
                local server_pid=$!
                sleep 2

                if ! kill -0 $server_pid 2>/dev/null; then
                    echo "RUNTIME_ERROR: Server failed to start - check for missing dependencies or syntax errors"
                else
                    # Check if server responds
                    if command -v curl >/dev/null 2>&1; then
                        local response
                        response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3000/" 2>/dev/null || echo "000")
                        if [[ "$response" == "000" ]]; then
                            echo "RUNTIME_ERROR: Server started but not responding on port 3000"
                        elif [[ "$response" == "500" ]]; then
                            echo "RUNTIME_ERROR: Server returns 500 error on main page"
                        fi
                    fi
                    kill $server_pid 2>/dev/null || true
                fi
            fi
        fi
    )
}

# ── Build Fix Prompt ────────────────────────────────────────────────────────

# Build the prompt for the fixer agent
# Usage: build_fix_prompt <errors> <issues> [dir]
build_fix_prompt() {
    local errors="$1"
    local issues="$2"
    local dir="${3:-.}"

    local project_info
    project_info=$(detect_project_type "$dir")
    local project_type
    project_type=$(echo "$project_info" | jq -r '.type')

    cat <<EOF
# Fix Integration Issues

## Project Type
${project_type}

## Validation Errors
\`\`\`
${errors}
\`\`\`

## Detected Issues
\`\`\`
${issues}
\`\`\`

## Instructions

1. Read the relevant files to understand the full context
2. Fix ALL the issues listed above
3. Common fixes needed:

   **MODULE_MISMATCH**: Convert all files to use the same style (ESM preferred for Node.js)

   **ID_MISMATCH**: Update JavaScript to use the IDs that actually exist in HTML
   - If JS has getElementById('taskForm') but HTML has id="task-form", fix JS to use 'task-form'

   **CSS_MISMATCH**: JS references a CSS class that doesn't exist
   - Add the missing class to your CSS file
   - OR fix the JavaScript to use the correct class name that exists in CSS

   **SELECTOR_MISMATCH**: querySelector('#x') or querySelector('.x') targets don't exist
   - Add the missing element ID or class to HTML
   - OR fix the selector in JavaScript

   **FIELD_MISMATCH**: Frontend uses camelCase for snake_case API fields
   - Change frontend to use exact field names from the API
   - If backend returns 'user_id', frontend must use data.user_id NOT data.userId

   **IMPORT_EXTENSION**: ESM imports missing .js extension
   - Add .js extension to local imports: from './utils.js' not from './utils'

   **RUNTIME_ERROR**: Server fails to start or respond
   - Check for missing imports, syntax errors, or missing dependencies
   - Verify all imported modules are installed

4. After fixing, verify your changes would resolve the errors
5. Do NOT add new features - only fix integration issues
6. Do NOT refactor beyond what's needed to fix the issues

## Critical Rules
- Match the existing code style
- Don't change functionality, only fix integration
- Test that imports/exports match
- Test that HTML IDs match JavaScript references
- Test that CSS class names match between JS/HTML/CSS
- Test that API field names match between frontend and backend
EOF
}

# ── Run Fixer Agent ─────────────────────────────────────────────────────────

# Run the fixer agent to resolve issues
# Usage: run_fixer_agent <errors> <issues> [dir]
run_fixer_agent() {
    local errors="$1"
    local issues="$2"
    local dir="${3:-.}"

    local fix_prompt
    fix_prompt=$(build_fix_prompt "$errors" "$issues" "$dir")

    local system_prompt="You are an expert code fixer. Your job is to fix integration issues in code that was written by multiple workers in parallel. Focus only on fixing the specific issues identified - do not refactor or add features."

    # Get provider:model spec for fixer
    local fixer_spec
    fixer_spec=$(resolve_provider_spec fixer)

    printf "${DIM}Running fixer agent...${NC}\n"

    local output
    output=$(cd "$dir" && invoke_llm "$fixer_spec" "$fix_prompt" \
        --system-prompt "$system_prompt" \
        --output-format json \
        --allowed-tools "Read,Edit,Write,Glob,Grep,Bash(npm:*),Bash(node:*)" \
        --max-turns 30 \
        2>&1) || {
        printf "${RED}Fixer agent failed${NC}\n"
        return 1
    }

    printf "${GREEN}Fixer agent completed${NC}\n"
    return 0
}

# ── Main Fix Command ────────────────────────────────────────────────────────

# Main entry point for the fix command
# Usage: run_fix_command [dir]
run_fix_command() {
    local dir="${1:-.}"
    local max_attempts="${SWARMTOOL_FIX_MAX_ATTEMPTS:-3}"
    local attempt=1

    print_header "Fix"

    printf "Analyzing project for integration issues...\n\n"

    while [[ $attempt -le $max_attempts ]]; do
        printf "${BOLD}Attempt ${attempt}/${max_attempts}${NC}\n"

        # Step 1: Validate the project
        printf "  ${DIM}[1/3]${NC} Validating project...\n"
        local validation
        validation=$(validate_project "$dir")

        local success
        success=$(echo "$validation" | jq -r '.success')
        local errors
        errors=$(echo "$validation" | jq -r '.errors // ""')

        # Step 2: Analyze for integration issues
        printf "  ${DIM}[2/3]${NC} Analyzing integration issues...\n"
        local issues
        issues=$(analyze_integration_issues "$dir")

        # Step 3: Check if we're done
        if [[ "$success" == "true" ]] && [[ -z "$issues" ]]; then
            printf "\n${GREEN}${BOLD}✓ All issues resolved!${NC}\n"
            printf "Project validates successfully with no integration issues.\n"
            return 0
        fi

        # Show what we found
        if [[ -n "$errors" && "$errors" != "null" ]]; then
            printf "\n${YELLOW}Validation errors:${NC}\n"
            echo "$errors" | head -20
        fi

        if [[ -n "$issues" ]]; then
            printf "\n${YELLOW}Integration issues:${NC}\n"
            echo "$issues"
        fi

        # Step 4: Run fixer agent
        printf "\n  ${DIM}[3/3]${NC} Running fixer agent...\n"
        if run_fixer_agent "$errors" "$issues" "$dir"; then
            printf "\n${DIM}Verifying fixes...${NC}\n"
        else
            printf "${RED}Fixer agent encountered an error${NC}\n"
        fi

        attempt=$((attempt + 1))

        if [[ $attempt -le $max_attempts ]]; then
            printf "\n${DIM}Re-validating...${NC}\n\n"
        fi
    done

    # Final check
    local final_validation
    final_validation=$(validate_project "$dir")
    local final_success
    final_success=$(echo "$final_validation" | jq -r '.success')

    if [[ "$final_success" == "true" ]]; then
        printf "\n${GREEN}${BOLD}✓ Project fixed successfully!${NC}\n"
        return 0
    else
        printf "\n${RED}${BOLD}✗ Could not fully resolve all issues after ${max_attempts} attempts${NC}\n"
        printf "Manual intervention may be required.\n"
        return 1
    fi
}

# ── Quick Fix (non-AI) ──────────────────────────────────────────────────────

# Apply quick fixes without AI for common issues
# Usage: quick_fix [dir]
quick_fix() {
    local dir="${1:-.}"
    local fixes_applied=0

    printf "Applying quick fixes...\n"

    (
        cd "$dir" || exit 1

        # Fix 1: Add "type": "module" if ESM imports detected but not set
        if [[ -f "package.json" ]]; then
            if ! grep -q '"type"' package.json; then
                if grep -rq "^import " --include="*.js" . 2>/dev/null; then
                    printf "  ${GREEN}+${NC} Adding \"type\": \"module\" to package.json\n"
                    # Use jq to add type field
                    local tmp
                    tmp=$(mktemp)
                    jq '. + {"type": "module"}' package.json > "$tmp" && mv "$tmp" package.json
                    fixes_applied=$((fixes_applied + 1))
                fi
            fi
        fi

        # Fix 2: Add .js extensions to local ESM imports
        if [[ -f "package.json" ]] && grep -q '"type":\s*"module"' package.json 2>/dev/null; then
            for file in $(find . -name "*.js" -not -path "./node_modules/*" 2>/dev/null); do
                if grep -q "from '\.\/" "$file" 2>/dev/null; then
                    # Check for imports without .js
                    if grep -qE "from '\./[^']+[^s]'" "$file" 2>/dev/null; then
                        if ! grep -qE "from '\./[^']+\.js'" "$file" 2>/dev/null; then
                            printf "  ${YELLOW}!${NC} $file may need .js extensions added to imports\n"
                        fi
                    fi
                fi
            done
        fi
    )

    if [[ $fixes_applied -gt 0 ]]; then
        printf "\nApplied ${fixes_applied} quick fix(es)\n"
    else
        printf "No quick fixes needed\n"
    fi

    return 0
}
