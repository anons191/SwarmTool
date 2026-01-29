#!/usr/bin/env bash
# install.sh -- Install swarmtool via curl or locally
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/anons191/SwarmTool/main/install.sh | bash
#   curl -sL https://raw.githubusercontent.com/anons191/SwarmTool/main/install.sh | bash -s -- --local
#   curl -sL https://raw.githubusercontent.com/anons191/SwarmTool/main/install.sh | bash -s -- --uninstall
#
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/anons191/SwarmTool.git"
GLOBAL_INSTALL_DIR="${HOME}/.swarmtool"
GLOBAL_BIN_DIR="/usr/local/bin"
LOCAL_INSTALL_DIR="./bin"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ─────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}==>${NC} $1"; }
success() { echo -e "${GREEN}==>${NC} $1"; }
warn()    { echo -e "${YELLOW}==>${NC} $1"; }
error()   { echo -e "${RED}==>${NC} $1"; }

# ── Prerequisite Check ──────────────────────────────────────────────────────
check_prerequisites() {
    local missing=0

    if ! command -v git >/dev/null 2>&1; then
        error "Missing: git"
        missing=1
    fi

    if ! command -v claude >/dev/null 2>&1; then
        warn "Missing: claude (Claude Code CLI)"
        echo "    Install from: https://docs.anthropic.com/en/docs/claude-code"
        echo "    SwarmTool will be installed, but won't work without it."
    fi

    if ! command -v jq >/dev/null 2>&1; then
        error "Missing: jq"
        echo "    Install with: brew install jq (macOS) or apt install jq (Linux)"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        error "Install missing prerequisites and try again."
        exit 1
    fi
}

# ── Global Install ──────────────────────────────────────────────────────────
install_global() {
    echo ""
    echo -e "${BOLD}SwarmTool Installer${NC}"
    echo ""

    check_prerequisites

    info "Installing swarmtool globally..."

    # Clone or update the repo
    if [[ -d "$GLOBAL_INSTALL_DIR" ]]; then
        info "Updating existing installation..."
        git -C "$GLOBAL_INSTALL_DIR" pull --ff-only origin main || {
            warn "Could not update. Re-cloning..."
            rm -rf "$GLOBAL_INSTALL_DIR"
            git clone --depth 1 "$REPO_URL" "$GLOBAL_INSTALL_DIR"
        }
    else
        info "Cloning SwarmTool..."
        git clone --depth 1 "$REPO_URL" "$GLOBAL_INSTALL_DIR"
    fi

    # Create symlink
    info "Creating symlink in ${GLOBAL_BIN_DIR}..."

    if [[ -w "$GLOBAL_BIN_DIR" ]]; then
        ln -sf "${GLOBAL_INSTALL_DIR}/swarmtool" "${GLOBAL_BIN_DIR}/swarmtool"
    else
        sudo ln -sf "${GLOBAL_INSTALL_DIR}/swarmtool" "${GLOBAL_BIN_DIR}/swarmtool"
    fi

    echo ""
    success "SwarmTool installed successfully!"
    echo ""
    echo "    Location: ${GLOBAL_INSTALL_DIR}"
    echo "    Binary:   ${GLOBAL_BIN_DIR}/swarmtool"
    echo ""
    echo "    Run 'swarmtool --help' to get started."
    echo ""

    # Verify
    if command -v swarmtool >/dev/null 2>&1; then
        success "Verified: swarmtool is in your PATH"
    else
        warn "You may need to restart your terminal or add ${GLOBAL_BIN_DIR} to PATH"
    fi
}

# ── Local/Project Install ───────────────────────────────────────────────────
install_local() {
    echo ""
    echo -e "${BOLD}SwarmTool Installer (Project Mode)${NC}"
    echo ""

    check_prerequisites

    # Check we're in a git repo
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        error "Not inside a git repository."
        echo "    Run this from your project's root directory."
        exit 1
    fi

    info "Installing swarmtool into ${LOCAL_INSTALL_DIR}..."

    # Create temp directory for clone
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT

    # Clone repo
    git clone --depth 1 "$REPO_URL" "$tmp_dir/swarmtool" 2>/dev/null

    # Create local bin directory
    mkdir -p "$LOCAL_INSTALL_DIR"

    # Copy files
    cp "$tmp_dir/swarmtool/swarmtool" "${LOCAL_INSTALL_DIR}/swarmtool"
    cp "$tmp_dir/swarmtool/defaults.conf" "${LOCAL_INSTALL_DIR}/swarmtool-defaults.conf"
    cp -r "$tmp_dir/swarmtool/lib" "${LOCAL_INSTALL_DIR}/swarmtool-lib"
    cp -r "$tmp_dir/swarmtool/prompts" "${LOCAL_INSTALL_DIR}/swarmtool-prompts"

    # Patch the main script to use local paths
    cat > "${LOCAL_INSTALL_DIR}/swarmtool" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SWARMTOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
export SWARMTOOL_DIR

# Remap paths for bundled install
_original_swarmtool_dir="$SWARMTOOL_DIR"
SCRIPT

    # Append original script with modified paths
    tail -n +6 "$tmp_dir/swarmtool/swarmtool" | \
        sed 's|"${SWARMTOOL_DIR}/lib/|"${SWARMTOOL_DIR}/swarmtool-lib/|g' | \
        sed 's|"${SWARMTOOL_DIR}/prompts/|"${SWARMTOOL_DIR}/swarmtool-prompts/|g' | \
        sed 's|"${SWARMTOOL_DIR}/defaults.conf"|"${SWARMTOOL_DIR}/swarmtool-defaults.conf"|g' \
        >> "${LOCAL_INSTALL_DIR}/swarmtool"

    chmod +x "${LOCAL_INSTALL_DIR}/swarmtool"

    echo ""
    success "SwarmTool installed into project!"
    echo ""
    echo "    ${LOCAL_INSTALL_DIR}/"
    echo "    ├── swarmtool"
    echo "    ├── swarmtool-defaults.conf"
    echo "    ├── swarmtool-lib/"
    echo "    └── swarmtool-prompts/"
    echo ""
    echo "    Run with: ${LOCAL_INSTALL_DIR}/swarmtool \"Your goal\""
    echo ""
    echo "    Or add to package.json:"
    echo "    \"scripts\": { \"swarm\": \"./bin/swarmtool\" }"
    echo ""
    warn "Tip: Commit ${LOCAL_INSTALL_DIR}/ to share with your team"
}

# ── Uninstall ───────────────────────────────────────────────────────────────
uninstall() {
    echo ""
    echo -e "${BOLD}SwarmTool Uninstaller${NC}"
    echo ""

    local removed=0

    # Remove symlink
    if [[ -L "${GLOBAL_BIN_DIR}/swarmtool" ]]; then
        info "Removing ${GLOBAL_BIN_DIR}/swarmtool..."
        if [[ -w "$GLOBAL_BIN_DIR" ]]; then
            rm -f "${GLOBAL_BIN_DIR}/swarmtool"
        else
            sudo rm -f "${GLOBAL_BIN_DIR}/swarmtool"
        fi
        removed=1
    fi

    # Remove installation directory
    if [[ -d "$GLOBAL_INSTALL_DIR" ]]; then
        info "Removing ${GLOBAL_INSTALL_DIR}..."
        rm -rf "$GLOBAL_INSTALL_DIR"
        removed=1
    fi

    if [[ $removed -eq 1 ]]; then
        echo ""
        success "SwarmTool uninstalled."
    else
        warn "SwarmTool was not installed globally."
    fi
}

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat << EOF
${BOLD}SwarmTool Installer${NC}

${BOLD}USAGE${NC}
    Global install (recommended):
        curl -sL https://raw.githubusercontent.com/anons191/SwarmTool/main/install.sh | bash

    Project install:
        curl -sL https://raw.githubusercontent.com/anons191/SwarmTool/main/install.sh | bash -s -- --local

    Uninstall:
        curl -sL https://raw.githubusercontent.com/anons191/SwarmTool/main/install.sh | bash -s -- --uninstall

${BOLD}OPTIONS${NC}
    --local       Install into current project (./bin/swarmtool)
    --uninstall   Remove global installation
    --help        Show this help message

EOF
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --local|-l)
            install_local
            ;;
        --uninstall|-u)
            uninstall
            ;;
        --help|-h)
            usage
            ;;
        "")
            install_global
            ;;
        *)
            error "Unknown option: $1"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
