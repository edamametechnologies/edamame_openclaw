#!/bin/bash
# build_posture.sh - Build edamame_posture natively inside the Lima VM
#
# Cross-compilation from macOS to Linux fails due to pkg-config and native
# library dependencies (libpcap, GTK, etc.). This script builds the binary
# natively inside a running Lima VM where the host workspace is mounted rw.
#
# Prerequisites:
#   - Lima VM must be running (setup.sh or start.sh creates it)
#   - ../secrets/foundation.env must exist (compile-time env vars via envc!)
#   - First run installs Rust + build deps (~5 min); subsequent builds are incremental
#
# Usage:
#   ./setup/build_posture.sh                  # Build in default VM
#   VM_NAME=my-vm ./setup/build_posture.sh    # Build in specific VM
#
# Output:
#   /tmp/edamame_posture_build/release/edamame_posture (inside the VM)
#
# To deploy and restart the daemon after building:
#   EDAMAME_POSTURE_BINARY=/tmp/edamame_posture_build/release/edamame_posture \
#     ./setup/start.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
VM_NAME="${VM_NAME:-openclaw-security}"
POSTURE_SRC="$(cd "$REPO_DIR/../edamame_posture" && pwd)"
SECRETS_DIR="$(cd "$REPO_DIR/../secrets" && pwd)"
BUILD_DIR="${LIMA_BUILD_DIR:-/tmp/edamame_posture_build}"

echo "=== Building edamame_posture natively in Lima VM '$VM_NAME' ==="
echo "  Source:  $POSTURE_SRC"
echo "  Secrets: $SECRETS_DIR/foundation.env"
echo "  Output:  $BUILD_DIR/release/edamame_posture"
echo ""

# Verify prerequisites
if ! command -v limactl &>/dev/null; then
    echo "ERROR: Lima not installed. Install with: brew install lima"
    exit 1
fi

STATUS=$(limactl list --json 2>/dev/null | jq -r "select(.name == \"$VM_NAME\") | .status" | sed -n '1p')
if [ "$STATUS" != "Running" ]; then
    echo "ERROR: VM '$VM_NAME' is not running (status: ${STATUS:-not found})."
    echo "  Start with: limactl start $VM_NAME"
    exit 1
fi

if [ ! -f "$SECRETS_DIR/foundation.env" ]; then
    echo "ERROR: Missing $SECRETS_DIR/foundation.env (compile-time secrets for envc! macros)"
    exit 1
fi

limactl shell "$VM_NAME" -- bash -c "
set -euo pipefail

# Source all compile-time secrets
set -a
source '$SECRETS_DIR/foundation.env'
for f in '$SECRETS_DIR/sentry.env' '$SECRETS_DIR/analytics.env' \
         '$SECRETS_DIR/edamame.env' '$SECRETS_DIR/lambda-signature.env'; do
    [ -f \"\$f\" ] && source \"\$f\" || true
done
set +a

# Install Rust if not present
if [ ! -f \$HOME/.cargo/env ]; then
    echo '--- Installing Rust toolchain ---'
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source \$HOME/.cargo/env

# Install build dependencies if needed (check clang for eBPF, libpcap-dev for capture)
if ! command -v clang >/dev/null 2>&1 || ! dpkg -s libpcap-dev >/dev/null 2>&1; then
    echo '--- Installing build dependencies (including eBPF toolchain) ---'
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends \
        build-essential pkg-config protobuf-compiler \
        libpcap-dev libgtk-3-dev libayatana-appindicator3-dev \
        clang llvm libelf-dev zlib1g-dev libbpf-dev \
        linux-headers-\$(uname -r) 2>/dev/null || true
fi

# Ensure enough memory for rustc (4GB swap if not already present)
if [ \$(free -m | awk '/^Swap:/ {print \$2}') -lt 1000 ]; then
    echo '--- Adding swap space for compilation ---'
    sudo fallocate -l 4G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=4096 2>/dev/null
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null
    sudo swapon /swapfile
fi

export CARGO_TARGET_DIR='$BUILD_DIR'
cd '$POSTURE_SRC'

echo '--- Building edamame_posture (release) ---'
cargo build --release 2>&1

echo ''
echo '=== Build complete ==='
ls -lh '$BUILD_DIR/release/edamame_posture'
file '$BUILD_DIR/release/edamame_posture'
"

echo ""
echo "Binary ready at: $BUILD_DIR/release/edamame_posture (inside VM '$VM_NAME')"
echo ""
echo "To deploy and restart the daemon:"
echo "  EDAMAME_POSTURE_BINARY=$BUILD_DIR/release/edamame_posture ./setup/start.sh"
