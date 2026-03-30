#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_DIR="$HOME/.openclaw"

if command -v openclaw >/dev/null 2>&1; then
  openclaw plugins disable edamame >/dev/null 2>&1 || true
fi

rm -rf \
  "$OPENCLAW_DIR/extensions/edamame" \
  "$OPENCLAW_DIR/skills/edamame-extrapolator" \
  "$OPENCLAW_DIR/skills/edamame-posture" \
  "$OPENCLAW_DIR/edamame-openclaw"

rm -f "$HOME/.edamame_openclaw_agent_instance_id"

echo "Uninstalled EDAMAME for OpenClaw from:"
echo "  $OPENCLAW_DIR"
