#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash setup/install.sh

Installs the EDAMAME plugin and skills into the local OpenClaw configuration
directory (~/.openclaw/). This is the lightweight local-install equivalent of
the full VM provisioner (setup/provision.sh).

What gets installed:
  - extensions/edamame/    MCP plugin (index.ts + manifest)
  - skills/edamame-*/      Extrapolator and posture skills
  - edamame-openclaw/      Package metadata (version tracking)

Prerequisites:
  - OpenClaw installed and ~/.openclaw/ directory exists (or will be created)
  - Optionally: `openclaw` CLI in PATH to enable the plugin automatically
EOF
}

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      echo "Unexpected argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCLAW_DIR="$HOME/.openclaw"

mkdir -p "$OPENCLAW_DIR/extensions/edamame"
mkdir -p "$OPENCLAW_DIR/skills/edamame-extrapolator"
mkdir -p "$OPENCLAW_DIR/skills/edamame-posture"
mkdir -p "$OPENCLAW_DIR/edamame-openclaw/state"
mkdir -p "$OPENCLAW_DIR/edamame-openclaw/service"

# Step 1: Install MCP plugin
PLUGIN_SRC="$SOURCE_ROOT/extensions/edamame"
PLUGIN_DST="$OPENCLAW_DIR/extensions/edamame"
if [ -f "$PLUGIN_SRC/openclaw.plugin.json" ] && [ -f "$PLUGIN_SRC/index.ts" ]; then
    cp "$PLUGIN_SRC/openclaw.plugin.json" "$PLUGIN_DST/openclaw.plugin.json"
    cp "$PLUGIN_SRC/index.ts" "$PLUGIN_DST/index.ts"
    echo "  edamame plugin installed to $PLUGIN_DST"
else
    echo "  WARNING: edamame plugin not found at $PLUGIN_SRC" >&2
fi

# Step 2: Install skills
SKILL_EX_SRC="$SOURCE_ROOT/skill/edamame-extrapolator"
SKILL_EX_DST="$OPENCLAW_DIR/skills/edamame-extrapolator"
if [ -f "$SKILL_EX_SRC/SKILL.md" ]; then
    cp "$SKILL_EX_SRC/SKILL.md" "$SKILL_EX_DST/SKILL.md"
    echo "  edamame-extrapolator skill installed"
else
    echo "  WARNING: SKILL.md not found at $SKILL_EX_SRC" >&2
fi

SKILL_POSTURE_SRC="$SOURCE_ROOT/skill/edamame-posture"
SKILL_POSTURE_DST="$OPENCLAW_DIR/skills/edamame-posture"
if [ -f "$SKILL_POSTURE_SRC/SKILL.md" ]; then
    cp "$SKILL_POSTURE_SRC/SKILL.md" "$SKILL_POSTURE_DST/SKILL.md"
    echo "  edamame-posture skill installed"
else
    echo "  WARNING: SKILL.md not found at $SKILL_POSTURE_SRC" >&2
fi

# Step 3: Copy package.json for version tracking
if [ -f "$SOURCE_ROOT/package.json" ]; then
    cp "$SOURCE_ROOT/package.json" "$OPENCLAW_DIR/edamame-openclaw/package.json"
fi

# Step 3b: Install healthcheck service files
SERVICE_SRC="$SOURCE_ROOT/service"
SERVICE_DST="$OPENCLAW_DIR/edamame-openclaw/service"
for f in healthcheck_cli.mjs health.mjs; do
    if [ -f "$SERVICE_SRC/$f" ]; then
        cp "$SERVICE_SRC/$f" "$SERVICE_DST/$f"
    fi
done
echo "  healthcheck service installed to $SERVICE_DST"

# Step 4: Enable the plugin if openclaw CLI is available
if command -v openclaw >/dev/null 2>&1; then
    openclaw plugins enable edamame 2>/dev/null || true
    echo "  edamame plugin enabled via openclaw CLI"
else
    echo "  openclaw CLI not found; enable the plugin manually or install OpenClaw first"
fi

# Read version from package.json
VERSION="unknown"
if [ -f "$SOURCE_ROOT/package.json" ]; then
    VERSION=$(python3 -c "import json; print(json.load(open('$SOURCE_ROOT/package.json'))['version'])" 2>/dev/null || echo "unknown")
fi

cat <<EOF

Installed EDAMAME for OpenClaw v${VERSION} to:
  Plugin:  $OPENCLAW_DIR/extensions/edamame/
  Skills:  $OPENCLAW_DIR/skills/edamame-extrapolator/
           $OPENCLAW_DIR/skills/edamame-posture/
  Version: $OPENCLAW_DIR/edamame-openclaw/package.json

Next steps:
1. Ensure OpenClaw is installed and configured (~/.openclaw/openclaw.json)
2. Start the EDAMAME MCP server (via EDAMAME app or edamame_posture)
3. Run: openclaw gateway restart  (to load the plugin)
EOF
