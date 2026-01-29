#!/usr/bin/env bash
# install.sh -- Install swarmtool globally or into a project
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARMTOOL_BIN="${SCRIPT_DIR}/swarmtool"

usage() {
    cat <<EOF
${BOLD}swarmtool installer${NC}

${BOLD}USAGE${NC}
    ./install.sh [MODE] [OPTIONS]

${BOLD}MODES${NC}
    global          Install swarmtool globally (symlink to /usr/local/bin)
    project         Install swarmtool into the current project (copy to ./bin/)
    uninstall       Remove global installation

${BOLD}OPTIONS${NC}
    --path <dir>    Custom install path (default: /usr/local/bin for global, ./bin for project)
    --help          Show this help message

${BOLD}EXAMPLES${NC}
    ./install.sh global                    # Symlink to /usr/local/bin/swarmtool
    ./install.sh global --path ~/bin       # Symlink to ~/bin/swarmtool
    ./install.sh project                   # Copy to ./bin/swarmtool
    ./install.sh project --path ./tools    # Copy to ./tools/swarmtool
    ./install.sh uninstall                 # Remove from /usr/local/bin

EOF
}

check_prerequisites() {
    local missing=0

    if ! command -v git >/dev/null 2>&1; then
        echo -e "${RED}Missing:${NC} git"
        missing=1
    fi

    if ! command -v claude >/dev/null 2>&1; then
        echo -e "${RED}Missing:${NC} claude (Claude Code CLI)"
        echo "  Install from: https://docs.anthropic.com/en/docs/claude-code"
        missing=1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}Missing:${NC} jq"
        echo "  Install with: brew install jq"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        echo -e "${YELLOW}Install the missing prerequisites and try again.${NC}"
        return 1
    fi

    echo -e "${GREEN}All prerequisites found.${NC}"
    return 0
}

install_global() {
    local install_path="${1:-/usr/local/bin}"
    local target="${install_path}/swarmtool"

    echo -e "${BOLD}Installing swarmtool globally...${NC}"
    echo ""

    # Check prerequisites
    check_prerequisites || exit 1
    echo ""

    # Create install directory if needed
    if [[ ! -d "$install_path" ]]; then
        echo -e "${YELLOW}Creating directory: ${install_path}${NC}"
        sudo mkdir -p "$install_path"
    fi

    # Remove existing installation
    if [[ -e "$target" || -L "$target" ]]; then
        echo -e "${YELLOW}Removing existing installation...${NC}"
        sudo rm -f "$target"
    fi

    # Create symlink
    echo "Symlinking: ${target} -> ${SWARMTOOL_BIN}"
    sudo ln -s "$SWARMTOOL_BIN" "$target"

    echo ""
    echo -e "${GREEN}Successfully installed!${NC}"
    echo ""
    echo "Run 'swarmtool --help' to get started."
    echo ""

    # Verify it works
    if command -v swarmtool >/dev/null 2>&1; then
        echo -e "${GREEN}Verified:${NC} swarmtool is available in PATH"
    else
        echo -e "${YELLOW}Note:${NC} You may need to add ${install_path} to your PATH:"
        echo "  export PATH=\"\$PATH:${install_path}\""
    fi
}

install_project() {
    local install_path="${1:-./bin}"
    local target="${install_path}/swarmtool"

    echo -e "${BOLD}Installing swarmtool into project...${NC}"
    echo ""

    # Check prerequisites
    check_prerequisites || exit 1
    echo ""

    # Check we're in a git repo
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo -e "${RED}Error:${NC} Not inside a git repository."
        echo "Run this command from your project's root directory."
        exit 1
    fi

    # Create install directory
    if [[ ! -d "$install_path" ]]; then
        echo "Creating directory: ${install_path}"
        mkdir -p "$install_path"
    fi

    # Copy swarmtool and its dependencies
    echo "Copying swarmtool to ${install_path}/"

    # Create the installation structure
    mkdir -p "${install_path}/swarmtool-lib"
    mkdir -p "${install_path}/swarmtool-prompts"

    # Copy main script
    cp "$SWARMTOOL_BIN" "$target"
    chmod +x "$target"

    # Copy libraries
    cp "${SCRIPT_DIR}/lib/"*.sh "${install_path}/swarmtool-lib/"

    # Copy prompts
    cp "${SCRIPT_DIR}/prompts/"*.txt "${install_path}/swarmtool-prompts/"

    # Copy config
    cp "${SCRIPT_DIR}/defaults.conf" "${install_path}/swarmtool-defaults.conf"

    # Patch the script to use local paths
    sed -i '' "s|SWARMTOOL_DIR=.*|SWARMTOOL_DIR=\"\$(cd \"\$(dirname \"\$0\")\" \&\& pwd)\"|" "$target"

    # Create a wrapper that sets up paths correctly
    cat > "$target" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

# Resolve installation directory
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
export SWARMTOOL_DIR="$INSTALL_DIR"

# Remap library and prompt paths
_SWARMTOOL_LIB_DIR="${INSTALL_DIR}/swarmtool-lib"
_SWARMTOOL_PROMPTS_DIR="${INSTALL_DIR}/swarmtool-prompts"
_SWARMTOOL_DEFAULTS="${INSTALL_DIR}/swarmtool-defaults.conf"

WRAPPER

    # Append the rest of the original script, modifying source paths
    tail -n +2 "$SWARMTOOL_BIN" | \
        sed "s|\${SWARMTOOL_DIR}/lib/|\${_SWARMTOOL_LIB_DIR}/|g" | \
        sed "s|\${SWARMTOOL_DIR}/prompts/|\${_SWARMTOOL_PROMPTS_DIR}/|g" | \
        sed "s|\${SWARMTOOL_DIR}/defaults.conf|\${_SWARMTOOL_DEFAULTS}|g" >> "$target"

    chmod +x "$target"

    echo ""
    echo -e "${GREEN}Successfully installed!${NC}"
    echo ""
    echo "Project structure:"
    echo "  ${install_path}/"
    echo "  ├── swarmtool              # Main executable"
    echo "  ├── swarmtool-lib/         # Library modules"
    echo "  ├── swarmtool-prompts/     # Prompt templates"
    echo "  └── swarmtool-defaults.conf"
    echo ""
    echo "Run it with:"
    echo "  ${target} \"Your goal here\""
    echo ""
    echo "Or add to your package.json scripts:"
    echo "  \"swarm\": \"./bin/swarmtool\""
    echo ""

    # Suggest adding to .gitignore or committing
    echo -e "${YELLOW}Tip:${NC} Commit the bin/ directory to share swarmtool with your team,"
    echo "     or add it to .gitignore if you prefer per-developer installs."
}

uninstall_global() {
    local install_path="${1:-/usr/local/bin}"
    local target="${install_path}/swarmtool"

    echo -e "${BOLD}Uninstalling swarmtool...${NC}"
    echo ""

    if [[ -e "$target" || -L "$target" ]]; then
        sudo rm -f "$target"
        echo -e "${GREEN}Removed:${NC} ${target}"
    else
        echo -e "${YELLOW}Not found:${NC} ${target}"
    fi

    echo ""
    echo "Uninstall complete."
}

# ── Main ────────────────────────────────────────────────────────────────────

MODE="${1:-}"
shift || true

INSTALL_PATH=""

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            INSTALL_PATH="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option:${NC} $1"
            usage
            exit 1
            ;;
    esac
done

case "$MODE" in
    global)
        install_global "$INSTALL_PATH"
        ;;
    project)
        install_project "$INSTALL_PATH"
        ;;
    uninstall)
        uninstall_global "$INSTALL_PATH"
        ;;
    --help|-h|"")
        usage
        ;;
    *)
        echo -e "${RED}Unknown mode:${NC} $MODE"
        echo ""
        usage
        exit 1
        ;;
esac
