#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FAKE_HOME=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME"' EXIT

echo "--- Testing setup/install.sh ---"
echo "REPO_ROOT: $REPO_ROOT"
echo "FAKE_HOME: $FAKE_HOME"
echo ""

# Run install.sh with a fake HOME so it installs into $FAKE_HOME/.openclaw/
HOME="$FAKE_HOME" bash "$REPO_ROOT/setup/install.sh"

echo ""
echo "=== Validating installed structure ==="

FAIL=0

check_file() {
    if [ -f "$1" ]; then
        echo "  PASS: $1"
    else
        echo "  FAIL: missing $1"
        FAIL=1
    fi
}

check_file "$FAKE_HOME/.openclaw/extensions/edamame/openclaw.plugin.json"
check_file "$FAKE_HOME/.openclaw/extensions/edamame/index.ts"
check_file "$FAKE_HOME/.openclaw/skills/edamame-extrapolator/SKILL.md"
check_file "$FAKE_HOME/.openclaw/skills/edamame-posture/SKILL.md"
check_file "$FAKE_HOME/.openclaw/edamame-openclaw/package.json"

echo ""
echo "=== Validating package.json version field ==="
PKG="$FAKE_HOME/.openclaw/edamame-openclaw/package.json"
VERSION=$(python3 -c "import json; print(json.load(open('$PKG'))['version'])" 2>/dev/null || echo "")
if [ -n "$VERSION" ] && [ "$VERSION" != "null" ]; then
    echo "  PASS: version=$VERSION"
else
    echo "  FAIL: package.json missing or has no version field"
    FAIL=1
fi

echo ""
echo "=== Validating plugin manifest has expected fields ==="
MANIFEST="$FAKE_HOME/.openclaw/extensions/edamame/openclaw.plugin.json"
if python3 -c "import json; d=json.load(open('$MANIFEST')); assert 'name' in d, 'missing name'" 2>/dev/null; then
    echo "  PASS: manifest has 'name' field"
else
    echo "  FAIL: manifest missing 'name' field"
    FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "PASS --- install.sh test passed ---"
else
    echo "FAIL --- install.sh test failed ---"
    exit 1
fi
