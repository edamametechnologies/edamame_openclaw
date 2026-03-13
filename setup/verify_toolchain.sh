#!/bin/bash
# verify_toolchain.sh - Check known-good toolchain floors on host and VM.
#
# Usage:
#   ./setup/verify_toolchain.sh
set -euo pipefail

VM_NAME="${VM_NAME:-openclaw-security}"
NODE_MIN_VERSION="${NODE_MIN_VERSION:-22.12.0}"
OPENCLAW_MIN_VERSION="${OPENCLAW_MIN_VERSION:-2026.1.29}"

compare_versions() {
    # returns success when $1 >= $2 using sort -V
    [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

echo "============================================"
echo "  Toolchain Verification (Known-Good Floors)"
echo "============================================"
echo "VM: $VM_NAME"
echo "Node minimum: $NODE_MIN_VERSION"
echo "OpenClaw minimum: $OPENCLAW_MIN_VERSION"
echo ""

host_ok=1
vm_ok=1

if ! command -v limactl >/dev/null 2>&1; then
    echo "Host: limactl missing"
    host_ok=0
else
    echo "Host: limactl present"
fi

if command -v jq >/dev/null 2>&1; then
    echo "Host: jq present"
else
    echo "Host: jq missing"
    host_ok=0
fi

limactl_list_output="$(limactl list 2>/dev/null || true)"
if [[ "$limactl_list_output" != *"$VM_NAME"* ]]; then
    echo "VM: not found in limactl list"
    vm_ok=0
else
    vm_node=$(limactl shell "$VM_NAME" -- bash -lc "node -v 2>/dev/null || true" | tr -d '\r' | sed 's/^v//')
    vm_oc=$(limactl shell "$VM_NAME" -- bash -lc "export PATH=\$HOME/.npm-global/bin:\$PATH; openclaw --version 2>/dev/null | head -1 || true" | tr -d '\r')
    vm_edamame_path=$(limactl shell "$VM_NAME" -- bash -lc "command -v edamame_posture || true" | tr -d '\r')
    vm_curl_path=$(limactl shell "$VM_NAME" -- bash -lc "command -v curl || true" | tr -d '\r')

    if [ -n "$vm_node" ] && compare_versions "$vm_node" "$NODE_MIN_VERSION"; then
        echo "VM: Node version ok ($vm_node)"
    else
        echo "VM: Node version below floor or unavailable ($vm_node)"
        vm_ok=0
    fi

    if [ -n "$vm_oc" ] && compare_versions "$vm_oc" "$OPENCLAW_MIN_VERSION"; then
        echo "VM: OpenClaw version ok ($vm_oc)"
    else
        echo "VM: OpenClaw version below floor or unavailable ($vm_oc)"
        vm_ok=0
    fi

    if [ -n "$vm_edamame_path" ]; then
        echo "VM: edamame_posture present ($vm_edamame_path)"
    else
        echo "VM: edamame_posture missing from PATH"
        vm_ok=0
    fi

    if [ -n "$vm_curl_path" ]; then
        echo "VM: curl present ($vm_curl_path)"
    else
        echo "VM: curl missing from PATH"
        vm_ok=0
    fi
fi

echo ""
if [ $host_ok -eq 1 ] && [ $vm_ok -eq 1 ]; then
    echo "Toolchain check: PASS"
    exit 0
fi

echo "Toolchain check: FAIL"
exit 1
