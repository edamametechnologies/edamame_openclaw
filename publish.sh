#!/bin/bash
# publish.sh - Publish OpenClaw skills to ClawHub and build plugin bundle
#
# Usage:
#   ./publish.sh                    # Publish all skills + build plugin bundle
#   ./publish.sh --skills-only      # Publish skills to ClawHub only
#   ./publish.sh --plugin-only     # Build plugin bundle only (no ClawHub publish)
#   ./publish.sh --dry-run          # Show what would be done
#
# Prerequisites:
#   - clawhub CLI installed: npm i -g clawhub
#   - Authenticated: clawhub login
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
SKILL_DIR="$REPO_DIR/skill"
PLUGIN_DIR="$REPO_DIR/extensions/edamame-mcp"

DRY_RUN=0
SKILLS_ONLY=0
PLUGIN_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --skills-only) SKILLS_ONLY=1 ;;
        --plugin-only) PLUGIN_ONLY=1 ;;
        --help|-h)
            echo "Usage: $0 [--skills-only] [--plugin-only] [--dry-run]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

SKILLS=(
    "edamame-extrapolator"
    "edamame-posture"
)

extract_version() {
    python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$1"
}

extract_name() {
    python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$1"
}

# ──────────────────────────────────────────────
# Step 1: Validate prerequisites
# ──────────────────────────────────────────────
echo "=== Validate prerequisites ==="

if [ "$PLUGIN_ONLY" -eq 0 ]; then
    if ! command -v clawhub >/dev/null 2>&1; then
        echo "ERROR: clawhub CLI not found. Install with: npm i -g clawhub"
        exit 1
    fi

    if ! clawhub whoami >/dev/null 2>&1; then
        echo "ERROR: Not authenticated with ClawHub. Run: clawhub login"
        exit 1
    fi
    echo "  ClawHub CLI: $(clawhub whoami 2>&1 | head -1)"
fi

for skill in "${SKILLS[@]}"; do
    if [ ! -f "$SKILL_DIR/$skill/SKILL.md" ]; then
        echo "ERROR: Missing $SKILL_DIR/$skill/SKILL.md"
        exit 1
    fi
    if [ ! -f "$SKILL_DIR/$skill/clawhub.json" ]; then
        echo "ERROR: Missing $SKILL_DIR/$skill/clawhub.json"
        exit 1
    fi
done
echo "  All skill files present"

# ──────────────────────────────────────────────
# Step 2: Publish skills to ClawHub
# ──────────────────────────────────────────────
if [ "$PLUGIN_ONLY" -eq 0 ]; then
    echo ""
    echo "=== Publish skills to ClawHub ==="

    for skill in "${SKILLS[@]}"; do
        SKILL_PATH="$SKILL_DIR/$skill"
        VERSION="$(extract_version "$SKILL_PATH/clawhub.json")"
        NAME="$(extract_name "$SKILL_PATH/clawhub.json")"

        echo ""
        echo "--- Publishing: $NAME v$VERSION ---"

        if [ "$DRY_RUN" -eq 1 ]; then
            echo "  [DRY RUN] clawhub publish $SKILL_PATH \\"
            echo "    --slug $NAME --name \"$NAME\" --version $VERSION \\"
            echo "    --tags latest --changelog \"ClawHub release v$VERSION\""
        else
            clawhub publish "$SKILL_PATH" \
                --slug "$NAME" \
                --name "$NAME" \
                --version "$VERSION" \
                --tags latest \
                --changelog "ClawHub release v$VERSION" \
                || echo "  WARNING: Publish failed for $NAME (may already exist at this version)"
        fi
    done
fi

# ──────────────────────────────────────────────
# Step 3: Build plugin bundle (copy skills into plugin)
# ──────────────────────────────────────────────
if [ "$SKILLS_ONLY" -eq 0 ]; then
    echo ""
    echo "=== Build plugin bundle ==="

    PLUGIN_SKILLS_DIR="$PLUGIN_DIR/skills"

    for skill in "${SKILLS[@]}"; do
        DEST="$PLUGIN_SKILLS_DIR/$skill"
        mkdir -p "$DEST"
        cp "$SKILL_DIR/$skill/SKILL.md" "$DEST/SKILL.md"
        echo "  Copied $skill/SKILL.md -> plugin bundle"
    done

    PLUGIN_VERSION="$(extract_version "$PLUGIN_DIR/openclaw.plugin.json")"
    echo ""
    echo "  Plugin bundle built: edamame-mcp v$PLUGIN_VERSION"
    echo "  Skills bundled: ${SKILLS[*]}"
    echo ""
    echo "  To install the plugin locally:"
    echo "    cp -r extensions/edamame-mcp ~/.openclaw/extensions/edamame-mcp"
    echo "    openclaw plugins enable edamame-mcp"
fi

# ──────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────
echo ""
echo "=== Done ==="
if [ "$PLUGIN_ONLY" -eq 0 ]; then
    echo ""
    echo "  ClawHub install commands:"
    for skill in "${SKILLS[@]}"; do
        echo "    clawhub install $skill"
    done
fi
if [ "$SKILLS_ONLY" -eq 0 ]; then
    echo ""
    echo "  Plugin install (all-in-one):"
    echo "    cp -r extensions/edamame-mcp ~/.openclaw/extensions/"
    echo "    openclaw plugins enable edamame-mcp"
fi
echo ""
