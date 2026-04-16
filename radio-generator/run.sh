#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run.sh
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------- Colors (disabled if not a terminal) ----------------------------
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

log()  { echo -e "${CYAN}[run]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC}  $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[err]${NC}  $*" >&2; }

# ---------- Python ---------------------------------------------------------
PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" &>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    err "Python not found. Please install Python 3.9+."
    exit 1
fi

PYTHON_VERSION=$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
log "Python detected: $PYTHON ($PYTHON_VERSION)"

# ---------- Virtual environment --------------------------------------------
VENV_DIR="$SCRIPT_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
    log "Creating virtual environment..."
    "$PYTHON" -m venv "$VENV_DIR"
fi

# Activate the venv
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

# ---------- Python dependencies --------------------------------------------
if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
    log "Installing / verifying dependencies..."
    pip install --quiet --upgrade pip
    pip install --quiet -r "$SCRIPT_DIR/requirements.txt"
    ok "Dependencies OK"
else
    warn "requirements.txt not found, skipping installation."
fi

# ---------- Launch ---------------------------------------------------------
log "Starting radio generator..."
echo ""

"$PYTHON" "$SCRIPT_DIR/main.py" "$@"