#!/usr/bin/env bash
# Build the qcal binary. CalDAV account setup is handled in the DMS plugin settings.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCAL_BIN="$SCRIPT_DIR/qcal/qcal"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[1;34m'
NC='\033[0m'

info()  { printf "${BLUE}[*]${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}[+]${NC} %s\n" "$1"; }
err()   { printf "${RED}[!]${NC} %s\n" "$1" >&2; }

if [[ ! -x "$QCAL_BIN" ]]; then
    info "Building qcal..."
    if ! command -v go &>/dev/null; then
        err "Go is not installed. Install it for your distro:"
        echo "  Arch:          pacman -S go"
        echo "  Fedora:        dnf install golang"
        echo "  openSUSE:      zypper install go"
        echo "  Ubuntu/Debian: apt install golang-go"
        exit 1
    fi
    (cd "$SCRIPT_DIR/qcal" && make)
    ok "qcal built successfully"
else
    ok "qcal binary already built"
fi

echo ""
echo "Configure your CalDAV account in DMS Settings → Plugins → qCal Calendar."
