#!/bin/bash
# setup.sh - Master setup script for OpenClaw + EDAMAME Posture PoC
#
# Creates the Lima VM, boots it, and runs provisioning inside it.
# Run from the repo root on macOS.
#
# Usage: ./setup/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
VM_NAME="${VM_NAME:-openclaw-security}"
LIMA_TEMPLATE="${LIMA_TEMPLATE:-$SCRIPT_DIR/lima-openclaw.yaml}"
source "$REPO_DIR/tests/lib/vm_exec.sh"

echo "============================================"
echo "  OpenClaw Security PoC - Setup"
echo "============================================"
echo ""

# ── Step 1: Verify prerequisites ──────────────
echo "--- Step 1: Verifying prerequisites ---"

SECRETS_ROOT="$(dirname "$REPO_DIR")"
OPENAI_SECRETS_FILE="$SECRETS_ROOT/secrets/openai.env"
PRIMARY_SECRETS_FILE="$SECRETS_ROOT/secrets.env"
FOUNDRY_SECRETS_FILE="$SECRETS_ROOT/secrets/foundry.env"
OPENCLAW_MODEL_PROVIDER="${OPENCLAW_MODEL_PROVIDER:-foundry}"

case "$OPENCLAW_MODEL_PROVIDER" in
    auto)
        SECRET_CANDIDATES=("$PRIMARY_SECRETS_FILE" "$FOUNDRY_SECRETS_FILE" "$OPENAI_SECRETS_FILE")
        ;;
    openai)
        SECRET_CANDIDATES=("$OPENAI_SECRETS_FILE" "$PRIMARY_SECRETS_FILE")
        ;;
    foundry)
        SECRET_CANDIDATES=("$PRIMARY_SECRETS_FILE" "$FOUNDRY_SECRETS_FILE")
        ;;
    *)
        echo "ERROR: OPENCLAW_MODEL_PROVIDER must be one of: auto, openai, foundry"
        exit 1
        ;;
esac

SECRETS_FILE=""
SELECTED_PROVIDER=""
for candidate in "${SECRET_CANDIDATES[@]}"; do
    [ -f "$candidate" ] || continue

    HAS_OPENAI=1
    if ! bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; [ -n \"\${OPENAI_API_KEY:-}\" ]"; then
        HAS_OPENAI=0
    fi
    HAS_FOUNDRY=1
    if ! bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; [ -n \"\${FOUNDRY_API_KEY:-}\" ] && [ -n \"\${FOUNDRY_OPENAI_ENDPOINT:-\${FOUNDRY_OPENCLAW:-}}\" ]"; then
        HAS_FOUNDRY=0
    fi

    case "$OPENCLAW_MODEL_PROVIDER" in
        openai)
            if [ "$HAS_OPENAI" -eq 1 ]; then
                SECRETS_FILE="$candidate"
                SELECTED_PROVIDER="openai"
                break
            fi
            ;;
        foundry)
            if [ "$HAS_FOUNDRY" -eq 1 ]; then
                SECRETS_FILE="$candidate"
                SELECTED_PROVIDER="foundry"
                break
            fi
            ;;
        auto)
            if [ "$HAS_FOUNDRY" -eq 1 ]; then
                SECRETS_FILE="$candidate"
                SELECTED_PROVIDER="foundry"
                break
            fi
            if [ "$HAS_OPENAI" -eq 1 ]; then
                SECRETS_FILE="$candidate"
                SELECTED_PROVIDER="openai"
                break
            fi
            ;;
    esac
done

if [ -z "$SECRETS_FILE" ] || [ -z "$SELECTED_PROVIDER" ]; then
    echo "ERROR: Could not find compatible credentials for provider '$OPENCLAW_MODEL_PROVIDER'."
    echo "Checked files:"
    printf '  - %s\n' "${SECRET_CANDIDATES[@]}"
    echo "Expected either:"
    echo "  OPENAI_API_KEY (default, gpt-5.1 path), or"
    echo "  FOUNDRY_API_KEY + FOUNDRY_OPENAI_ENDPOINT."
    exit 1
fi
echo "  Secrets file: $SECRETS_FILE"
echo "  Model provider: $SELECTED_PROVIDER (requested: $OPENCLAW_MODEL_PROVIDER)"

if ! command -v limactl &>/dev/null; then
    echo "  Lima not found. Installing via Homebrew..."
    brew install lima
fi
echo "  Lima: $(limactl --version 2>/dev/null | head -1)"

if ! command -v jq &>/dev/null; then
    echo "  jq not found. Installing via Homebrew..."
    brew install jq
fi
echo "  jq: $(jq --version)"

if [ -f "$SCRIPT_DIR/verify_toolchain.sh" ]; then
    echo "  Toolchain verifier available: $SCRIPT_DIR/verify_toolchain.sh"
fi

# ── Step 2: Create Lima VM ────────────────────
echo ""
echo "--- Step 2: Creating Lima VM '$VM_NAME' ---"

# NOTE: `limactl list --json` outputs NDJSON (one JSON object per line), not a JSON array.
if limactl list --json 2>/dev/null | jq -e "select(.name == \"$VM_NAME\")" &>/dev/null; then
    echo "  VM '$VM_NAME' already exists."
    read -p "  Delete and recreate? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Optional: VM may already be stopped or not exist
        limactl stop "$VM_NAME" 2>/dev/null || true
        limactl delete "$VM_NAME" --force 2>/dev/null || true
    else
        echo "  Keeping existing VM. Run ./setup/start.sh to start services."
        exit 0
    fi
fi

echo "  Creating VM from template..."
limactl create --name="$VM_NAME" "$LIMA_TEMPLATE"

echo "  Starting VM (first boot takes several minutes for package installs)..."
limactl start "$VM_NAME"
echo "  VM is running."

# ── Step 3: Run provisioning inside VM ────────
echo ""
echo "--- Step 3: Running provisioning ---"

# Copy files into the VM
vm_exec "mkdir -p /tmp/openclaw_security/setup /tmp/openclaw_security/skill/edamame-extrapolator /tmp/openclaw_security/skill/edamame-posture /tmp/openclaw_security/extensions/edamame-mcp"

limactl cp "$SCRIPT_DIR/provision.sh" "$VM_NAME:/tmp/openclaw_security/setup/provision.sh"

for SKILL_NAME in edamame-extrapolator edamame-posture; do
    if [ -f "$REPO_DIR/skill/$SKILL_NAME/SKILL.md" ]; then
        limactl cp "$REPO_DIR/skill/$SKILL_NAME/SKILL.md" \
            "$VM_NAME:/tmp/openclaw_security/skill/$SKILL_NAME/SKILL.md"
    fi
    if [ -f "$REPO_DIR/skill/$SKILL_NAME/clawhub.json" ]; then
        limactl cp "$REPO_DIR/skill/$SKILL_NAME/clawhub.json" \
            "$VM_NAME:/tmp/openclaw_security/skill/$SKILL_NAME/clawhub.json"
    fi
done

# Copy OpenClaw plugin extension that exposes EDAMAME MCP tools as native tools.
if [ -f "$REPO_DIR/extensions/edamame-mcp/openclaw.plugin.json" ]; then
    limactl cp "$REPO_DIR/extensions/edamame-mcp/openclaw.plugin.json" \
        "$VM_NAME:/tmp/openclaw_security/extensions/edamame-mcp/openclaw.plugin.json"
fi
if [ -f "$REPO_DIR/extensions/edamame-mcp/index.ts" ]; then
    limactl cp "$REPO_DIR/extensions/edamame-mcp/index.ts" \
        "$VM_NAME:/tmp/openclaw_security/extensions/edamame-mcp/index.ts"
fi

# Run provisioning
vm_exec_raw env SECRETS_FILE="$SECRETS_FILE" OPENCLAW_MODEL_PROVIDER="$SELECTED_PROVIDER" EDAMAME_POSTURE_BINARY="${EDAMAME_POSTURE_BINARY:-}" bash -l /tmp/openclaw_security/setup/provision.sh

echo ""
echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
echo "  VM Name:       $VM_NAME"
echo "  Dashboard:     http://localhost:18789/"
echo "  EDAMAME MCP:   http://localhost:3001/mcp (host) / :3000 (VM)"
echo ""
echo "  Enter VM:      limactl shell $VM_NAME"
echo "  Stop:          ./setup/stop.sh"
echo "  Start:         ./setup/start.sh"
echo "  Test:          ./tests/test_poc.sh"
echo "  Test runner:   ./tests/run_tests.sh --suite full"
echo ""
