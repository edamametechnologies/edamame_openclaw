#!/bin/bash
# stop.sh - Stop all services and optionally the Lima VM
#
# Usage: ./setup/stop.sh [--keep-vm]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
VM_NAME="${VM_NAME:-openclaw-security}"
KEEP_VM=false
[ "${1:-}" = "--keep-vm" ] && KEEP_VM=true

source "$REPO_DIR/tests/lib/vm_exec.sh"

echo "============================================"
echo "  Stopping OpenClaw Security PoC"
echo "============================================"
echo ""

STATUS=$(limactl list --json 2>/dev/null | jq -r "select(.name == \"$VM_NAME\") | .status" 2>/dev/null | sed -n '1p' || true)
STATUS="${STATUS:-NotFound}"

if [ "$STATUS" = "Running" ]; then
    # Stop OpenClaw gateway
    echo "--- Stopping OpenClaw ---"
    vm_exec 'export PATH="$HOME/.npm-global/bin:$PATH"
        pkill -f "openclaw-gatewa" 2>/dev/null || true
        echo "  OpenClaw processes stopped."' 2>/dev/null || true

    # Stop EDAMAME Posture
    echo ""
    echo "--- Stopping EDAMAME Posture ---"
    vm_exec 'sudo edamame_posture background-mcp-stop 2>/dev/null || true
        echo "  MCP server stopped."
        if command -v systemctl >/dev/null 2>&1; then
            sudo systemctl stop edamame_posture 2>/dev/null || true
        fi
        sudo edamame_posture background-stop 2>/dev/null || true
        echo "  Daemon stopped."' 2>/dev/null || true

    if [ "$KEEP_VM" = true ]; then
        echo ""
        echo "  Services stopped. VM still running."
        echo "  Stop VM: limactl stop $VM_NAME"
    else
        echo ""
        echo "--- Stopping Lima VM ---"
        limactl stop "$VM_NAME"
        echo "  VM stopped."
    fi
else
    echo "  VM '$VM_NAME' is not running (status: $STATUS)."
fi

echo ""
echo "  Done."
