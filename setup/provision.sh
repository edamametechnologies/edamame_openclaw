#!/bin/bash
# provision.sh - Configure services inside the Lima VM after boot
#
# This script is run inside the VM by setup.sh. It:
#   1.  Loads OpenClaw model credentials from host-mounted secrets
#   1a. Loads EDAMAME internal LLM credentials (divergence engine)
#   2.  Starts EDAMAME Posture daemon with agentic features + MCP server
#   3.  Configures OpenClaw runtime (local gateway)
#   4.  Installs the OpenClaw plugin `edamame` (native EDAMAME MCP tools)
#   5.  Installs the extrapolator + edamame-posture skills (divergence detection is internal)
#   6.  Starts the OpenClaw gateway
#   7.  Verifies OpenClaw-native MCP tool path
#
# Usage: limactl shell openclaw-security -- bash /path/to/provision.sh
#
# Optional env vars:
#   EDAMAME_POSTURE_BINARY - Path to a pre-built edamame_posture binary. When set,
#                           this binary is installed directly (skipping APT). Useful
#                           for cross-compiled binaries or local dev builds.
#   EDAMAME_LLM_PROVIDER  - LLM provider for EDAMAME internal divergence engine.
#                            One of: edamame (default), openai, claude, ollama, none.
#                            edamame uses the EDAMAME Portal managed LLM.
#   EDAMAME_LLM_API_KEY   - API key for the selected provider (auto-loaded from
#                            ../secrets/edamame-llm.env for edamame).
#   EDAMAME_LLM_MODEL     - Override default model name for the selected provider.
#   EDAMAME_LLM_BASE_URL  - Base URL (for ollama or custom OpenAI-compatible).
#   EDAMAME_TELEGRAM_BOT_TOKEN - Telegram Bot API token for unified EDAMAME
#                               notifications (agentic todo loop + divergence loop).
#   EDAMAME_TELEGRAM_CHAT_ID   - Telegram chat ID for EDAMAME notifications.
#   EDAMAME_TELEGRAM_INTERACTIVE_ENABLED - Enable bidirectional Telegram mode
#                               ("true"/"1"). Sends inline-button cards for
#                               execute/undo/dismiss/restore actions.
#   EDAMAME_TELEGRAM_ALLOWED_USER_IDS - Comma-separated Telegram user IDs
#                               authorized to press interactive buttons.
#                               To find your user ID: message @userinfobot on
#                               Telegram, or call the getUpdates API:
#                                 curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | python3 -m json.tool
#                               and look for "from":{"id": ...} in the response.
#   EDAMAME_AGENTIC_SLACK_BOT_TOKEN - Slack bot token for unified EDAMAME
#                                     notifications.
#   EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL - Slack channel ID for routine summaries.
#   EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL - Slack channel ID for escalations
#                                               (defaults to actions channel when unset).
#   EXTRAPOLATOR_MODE - Extrapolator execution mode (default: compiled).
#                      compiled = zero OpenClaw LLM tokens; uses the
#                                 extrapolator_run_cycle plugin tool and
#                                 EDAMAME's internal LLM.
#                      llm      = full agent runbook; the OpenClaw agent
#                                 LLM reads transcripts and builds the model.
#   ALERT_TO       - Recipient for conditional alerts (E.164 for WhatsApp, chat ID for
#                    Telegram, etc). Skills send alerts only when actionable conditions
#                    are detected (DIVERGENCE verdict, escalated posture items).
#   ALERT_CHANNEL  - Delivery channel (default: whatsapp). Supports: whatsapp,
#                    telegram, discord, signal, slack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=./agent_identity.sh
source "$SCRIPT_DIR/agent_identity.sh"
ALERT_TO="${ALERT_TO:-}"
ALERT_CHANNEL="${ALERT_CHANNEL:-whatsapp}"

echo "============================================"
echo "  OpenClaw + EDAMAME Posture Provisioner"
echo "============================================"

# Prefer user-local toolchains when available.
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

# ──────────────────────────────────────────────
# Step 1: Load model credentials
# ──────────────────────────────────────────────
echo ""
echo "--- Step 1: Loading model credentials (OpenAI/Foundry) ---"

SECRET_CANDIDATES=()
if [ -n "${SECRETS_FILE:-}" ]; then
    SECRET_CANDIDATES+=("$SECRETS_FILE")
fi
if [ -n "${SECRETS_DIR:-}" ]; then
    SECRET_CANDIDATES+=(
        "$SECRETS_DIR/secrets.env"
        "$SECRETS_DIR/foundry.env"
        "$SECRETS_DIR/openai.env"
    )
fi
SECRET_CANDIDATES+=(
    "$REPO_DIR/../secrets.env"
    "$REPO_DIR/../secrets/foundry.env"
    "$REPO_DIR/../secrets/openai.env"
)

OPENCLAW_MODEL_PROVIDER="${OPENCLAW_MODEL_PROVIDER:-foundry}"
case "$OPENCLAW_MODEL_PROVIDER" in
    auto|openai|foundry) ;;
    *)
        echo "ERROR: OPENCLAW_MODEL_PROVIDER must be one of: auto, openai, foundry"
        exit 1
        ;;
esac

SECRETS_FILE_RESOLVED=""
FIRST_EXISTING_SECRETS=""
OPENAI_FALLBACK_FILE=""
for candidate in "${SECRET_CANDIDATES[@]}"; do
    if [ -z "$candidate" ] || [ ! -f "$candidate" ]; then
        continue
    fi
    if [ -z "$FIRST_EXISTING_SECRETS" ]; then
        FIRST_EXISTING_SECRETS="$candidate"
    fi

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
                SECRETS_FILE_RESOLVED="$candidate"
                break
            fi
            ;;
        foundry)
            if [ "$HAS_FOUNDRY" -eq 1 ]; then
                SECRETS_FILE_RESOLVED="$candidate"
                break
            fi
            ;;
        auto)
            if [ "$HAS_FOUNDRY" -eq 1 ]; then
                SECRETS_FILE_RESOLVED="$candidate"
                break
            fi
            if [ "$HAS_OPENAI" -eq 1 ] && [ -z "$OPENAI_FALLBACK_FILE" ]; then
                OPENAI_FALLBACK_FILE="$candidate"
            fi
            ;;
    esac
done

if [ -z "$SECRETS_FILE_RESOLVED" ] && [ "$OPENCLAW_MODEL_PROVIDER" = "auto" ] && [ -n "$OPENAI_FALLBACK_FILE" ]; then
    SECRETS_FILE_RESOLVED="$OPENAI_FALLBACK_FILE"
fi

if [ -z "$SECRETS_FILE_RESOLVED" ]; then
    if [ -n "$FIRST_EXISTING_SECRETS" ]; then
        echo "ERROR: Secrets file found but incompatible with OPENCLAW_MODEL_PROVIDER=$OPENCLAW_MODEL_PROVIDER"
        echo "File: $FIRST_EXISTING_SECRETS"
        echo "Expected OPENAI_API_KEY (openai) or FOUNDRY_API_KEY + FOUNDRY_OPENAI_ENDPOINT (foundry)."
    else
        echo "ERROR: No secrets file found."
        echo "Checked: ${SECRET_CANDIDATES[*]}"
        echo "Expected one of: openai.env, secrets.env, or foundry.env."
        echo "Ensure the host filesystem is mounted (Lima default: ~ is mounted read-only)."
    fi
    exit 1
fi

# shellcheck disable=SC1091
source "$SECRETS_FILE_RESOLVED"

normalize_foundry_endpoint() {
    local raw="${1:-}"
    local cleaned resource
    cleaned="${raw%%\?*}"
    cleaned="${cleaned%/}"
    if [ -z "$cleaned" ]; then
        echo ""
        return
    fi
    case "$cleaned" in
        https://*.services.ai.azure.com/*|http://*.services.ai.azure.com/*)
            resource="$(printf "%s" "$cleaned" | sed -E 's#https?://([^.]+)\.services\.ai\.azure\.com.*#\1#')"
            if [ -n "$resource" ]; then
                echo "https://${resource}.openai.azure.com/openai/v1"
            else
                echo "$cleaned"
            fi
            ;;
        https://*.openai.azure.com/openai/v1|http://*.openai.azure.com/openai/v1|https://*.cognitiveservices.azure.com/openai/v1|http://*.cognitiveservices.azure.com/openai/v1)
            echo "$cleaned"
            ;;
        https://*.openai.azure.com/openai/*|http://*.openai.azure.com/openai/*|https://*.cognitiveservices.azure.com/openai/*|http://*.cognitiveservices.azure.com/openai/*)
            echo "${cleaned%%/openai/*}/openai/v1"
            ;;
        https://*.openai.azure.com|http://*.openai.azure.com|https://*.cognitiveservices.azure.com|http://*.cognitiveservices.azure.com)
            echo "${cleaned}/openai/v1"
            ;;
        https://*|http://*)
            if printf "%s" "$cleaned" | grep -q "/openai/v1"; then
                echo "${cleaned%%/openai/v1*}/openai/v1"
            elif printf "%s" "$cleaned" | grep -q "/openai/"; then
                echo "${cleaned%%/openai/*}/openai/v1"
            else
                echo "${cleaned}/openai/v1"
            fi
            ;;
        *)
            echo "$cleaned"
            ;;
    esac
}

if [ -z "${FOUNDRY_OPENAI_ENDPOINT:-}" ] && [ -n "${FOUNDRY_OPENCLAW:-}" ]; then
    FOUNDRY_OPENAI_ENDPOINT="$(normalize_foundry_endpoint "$FOUNDRY_OPENCLAW")"
fi
if [ -n "${FOUNDRY_OPENAI_ENDPOINT:-}" ]; then
    FOUNDRY_OPENAI_ENDPOINT="$(normalize_foundry_endpoint "$FOUNDRY_OPENAI_ENDPOINT")"
fi

OPENAI_PRIMARY_MODEL="${OPENAI_PRIMARY_MODEL:-gpt-5.1}"
FOUNDRY_PRIMARY_MODEL="${FOUNDRY_PRIMARY_MODEL:-${FOUNDRY_DEPLOYMENT:-gpt-5.1}}"
FOUNDRY_CONTEXT_WINDOW="${FOUNDRY_CONTEXT_WINDOW:-128000}"
FOUNDRY_MAX_TOKENS="${FOUNDRY_MAX_TOKENS:-16384}"

MODEL_PROVIDER=""
case "$OPENCLAW_MODEL_PROVIDER" in
    openai)
        MODEL_PROVIDER="openai"
        ;;
    foundry)
        MODEL_PROVIDER="foundry"
        ;;
    auto)
        if [ -n "${FOUNDRY_API_KEY:-}" ] && [ -n "${FOUNDRY_OPENAI_ENDPOINT:-}" ]; then
            MODEL_PROVIDER="foundry"
        elif [ -n "${OPENAI_API_KEY:-}" ]; then
            MODEL_PROVIDER="openai"
        fi
        ;;
    *)
        echo "ERROR: OPENCLAW_MODEL_PROVIDER must be one of: auto, openai, foundry"
        exit 1
        ;;
esac

if [ "$MODEL_PROVIDER" = "openai" ]; then
    if [ -z "${OPENAI_API_KEY:-}" ]; then
        echo "ERROR: OPENAI_API_KEY is required for OPENCLAW_MODEL_PROVIDER=openai"
        exit 1
    fi
    export OPENAI_API_KEY OPENAI_PRIMARY_MODEL MODEL_PROVIDER
    echo "  Secrets source: $SECRETS_FILE_RESOLVED"
    echo "  Provider: openai"
    echo "  Model: $OPENAI_PRIMARY_MODEL"
elif [ "$MODEL_PROVIDER" = "foundry" ]; then
    if [ -z "${FOUNDRY_API_KEY:-}" ]; then
        echo "ERROR: FOUNDRY_API_KEY is required for OPENCLAW_MODEL_PROVIDER=foundry"
        exit 1
    fi
    if [ -z "${FOUNDRY_OPENAI_ENDPOINT:-}" ]; then
        echo "ERROR: FOUNDRY_OPENAI_ENDPOINT (or FOUNDRY_OPENCLAW) is required for OPENCLAW_MODEL_PROVIDER=foundry"
        exit 1
    fi
    FOUNDRY_BASE_URL="${FOUNDRY_OPENAI_ENDPOINT%/}"
    case "$FOUNDRY_BASE_URL" in
        */openai/v1) ;;
        *) FOUNDRY_BASE_URL="${FOUNDRY_BASE_URL}/openai/v1" ;;
    esac
    FOUNDRY_PRIMARY_MODEL_CANDIDATES=("$FOUNDRY_PRIMARY_MODEL")
    if [ -n "${FOUNDRY_DEPLOYMENT:-}" ]; then
        FOUNDRY_PRIMARY_MODEL_CANDIDATES+=("$FOUNDRY_DEPLOYMENT")
    fi
    FOUNDRY_PRIMARY_MODEL_CANDIDATES+=("gpt-5.1-2" "gpt-5.1")
    FOUNDRY_PRIMARY_MODEL="$(
        FOUNDRY_BASE_URL="$FOUNDRY_BASE_URL" FOUNDRY_API_KEY="$FOUNDRY_API_KEY" \
        FOUNDRY_PRIMARY_MODEL_CANDIDATES_RAW="$(printf '%s\n' "${FOUNDRY_PRIMARY_MODEL_CANDIDATES[@]}")" \
        python3 - <<'PY'
import json
import os
import urllib.error
import urllib.request

base = os.environ.get("FOUNDRY_BASE_URL", "").rstrip("/")
key = os.environ.get("FOUNDRY_API_KEY", "")
raw = os.environ.get("FOUNDRY_PRIMARY_MODEL_CANDIDATES_RAW", "")
candidates = []
for line in raw.splitlines():
    m = line.strip()
    if m and m not in candidates:
        candidates.append(m)

chosen = ""
for model in candidates:
    payload = {"model": model, "input": "healthcheck", "max_output_tokens": 256}
    req = urllib.request.Request(
        f"{base}/responses",
        data=json.dumps(payload).encode("utf-8"),
        headers={"api-key": key, "content-type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            if 200 <= r.status < 300:
                chosen = model
                break
    except urllib.error.HTTPError as e:
        body = e.read(500).decode("utf-8", "ignore").lower()
        # Keep probing only for model/deployment mismatch style errors.
        if e.code in (400, 404) and (
            "deployment" in body
            or "does not exist" in body
            or "invalid 'model'" in body
            or "deploymentnotfound" in body
        ):
            continue
    except Exception:
        continue

print(chosen or candidates[0] if candidates else "gpt-5.1")
PY
    )"
    export FOUNDRY_API_KEY FOUNDRY_BASE_URL FOUNDRY_PRIMARY_MODEL FOUNDRY_CONTEXT_WINDOW FOUNDRY_MAX_TOKENS MODEL_PROVIDER
    echo "  Secrets source: $SECRETS_FILE_RESOLVED"
    echo "  Provider: azure-openai-responses"
    echo "  Endpoint: $FOUNDRY_BASE_URL"
    echo "  Model: $FOUNDRY_PRIMARY_MODEL"
else
    echo "ERROR: no usable credentials found (OPENAI_API_KEY or FOUNDRY_*)."
    exit 1
fi

APT_FLAGS="-o Acquire::ForceIPv4=true -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"
APT_UPDATED=0
apt_update_once() {
    if [ "$APT_UPDATED" -eq 0 ]; then
        sudo env DEBIAN_FRONTEND=noninteractive apt-get ${APT_FLAGS} update -y
        APT_UPDATED=1
    fi
}
apt_install() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get ${APT_FLAGS} install -y --no-install-recommends "$@"
}

# ──────────────────────────────────────────────
# Step 1a: Load EDAMAME LLM + notification credentials
# ──────────────────────────────────────────────
echo ""
echo "--- Step 1a: Loading EDAMAME internal LLM + notification credentials ---"

# EDAMAME Posture has its own internal LLM for the divergence engine.
# This is independent of the OpenClaw agent LLM configured above.
#
# Supported providers (via EDAMAME_LLM_PROVIDER):
#   edamame  - EDAMAME Portal managed LLM (default). Key from ../secrets/edamame-llm.env.
#   openai   - OpenAI API key (reuses OPENAI_API_KEY from OpenClaw secrets).
#   claude   - Anthropic Claude API key (from ../secrets/claude.env).
#   ollama   - Local Ollama instance (requires EDAMAME_LLM_BASE_URL).
#   none     - Disable internal LLM (divergence engine runs without LLM).
EDAMAME_LLM_PROVIDER="${EDAMAME_LLM_PROVIDER:-edamame}"
case "$EDAMAME_LLM_PROVIDER" in
    edamame|openai|claude|ollama|none) ;;
    *)
        echo "ERROR: EDAMAME_LLM_PROVIDER must be one of: edamame, openai, claude, ollama, none"
        exit 1
        ;;
esac

EDAMAME_LLM_API_KEY="${EDAMAME_LLM_API_KEY:-}"
EDAMAME_LLM_MODEL="${EDAMAME_LLM_MODEL:-}"
EDAMAME_LLM_BASE_URL="${EDAMAME_LLM_BASE_URL:-}"
EDAMAME_TELEGRAM_BOT_TOKEN="${EDAMAME_TELEGRAM_BOT_TOKEN:-}"
EDAMAME_TELEGRAM_CHAT_ID="${EDAMAME_TELEGRAM_CHAT_ID:-}"
EDAMAME_TELEGRAM_INTERACTIVE_ENABLED="${EDAMAME_TELEGRAM_INTERACTIVE_ENABLED:-}"
EDAMAME_TELEGRAM_ALLOWED_USER_IDS="${EDAMAME_TELEGRAM_ALLOWED_USER_IDS:-}"
EDAMAME_AGENTIC_SLACK_BOT_TOKEN="${EDAMAME_AGENTIC_SLACK_BOT_TOKEN:-${EDAMAME_AGENTIC_WEBHOOK_ACTIONS_TOKEN:-}}"
EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL="${EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL:-${EDAMAME_AGENTIC_WEBHOOK_ACTIONS_CHANNEL:-}}"
EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL="${EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL:-${EDAMAME_AGENTIC_WEBHOOK_ESCALATIONS_CHANNEL:-}}"

if [ "$EDAMAME_LLM_PROVIDER" = "edamame" ] && [ -z "$EDAMAME_LLM_API_KEY" ]; then
    for candidate in \
        "${SECRETS_DIR:-/nonexistent}/edamame-llm.env" \
        "$REPO_DIR/../secrets/edamame-llm.env" \
        "$REPO_DIR/../secrets.env"; do
        if [ -f "$candidate" ]; then
            _key=$(bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; echo \"\${EDAMAME_LLM_API_KEY:-}\"")
            if [ -n "$_key" ]; then
                EDAMAME_LLM_API_KEY="$_key"
                echo "  Loaded EDAMAME LLM key from $candidate"
                break
            fi
        fi
    done
fi


# Load Telegram vars from telegram.env or edamame-llm.env if empty.
# telegram.env uses unprefixed names (TELEGRAM_BOT_TOKEN, etc.).
if [ -z "$EDAMAME_TELEGRAM_BOT_TOKEN" ] || [ -z "$EDAMAME_TELEGRAM_CHAT_ID" ] \
   || [ -z "$EDAMAME_TELEGRAM_INTERACTIVE_ENABLED" ] || [ -z "$EDAMAME_TELEGRAM_ALLOWED_USER_IDS" ]; then
    for candidate in \
        "${SECRETS_DIR:-/nonexistent}/telegram.env" \
        "$REPO_DIR/../secrets/telegram.env" \
        "${SECRETS_DIR:-/nonexistent}/edamame-llm.env" \
        "$REPO_DIR/../secrets/edamame-llm.env" \
        "$REPO_DIR/../secrets.env"; do
        if [ -f "$candidate" ]; then
            _tg_token=$(bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; echo \"\${TELEGRAM_BOT_TOKEN:-\${EDAMAME_TELEGRAM_BOT_TOKEN:-}}\"")
            _tg_chat=$(bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; echo \"\${TELEGRAM_CHAT_ID:-\${EDAMAME_TELEGRAM_CHAT_ID:-}}\"")
            _tg_interactive=$(bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; echo \"\${TELEGRAM_INTERACTIVE_ENABLED:-\${EDAMAME_TELEGRAM_INTERACTIVE_ENABLED:-}}\"")
            _tg_users=$(bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; echo \"\${TELEGRAM_ALLOWED_USER_IDS:-\${EDAMAME_TELEGRAM_ALLOWED_USER_IDS:-}}\"")
            [ -n "$_tg_token" ] && [ -z "$EDAMAME_TELEGRAM_BOT_TOKEN" ] && EDAMAME_TELEGRAM_BOT_TOKEN="$_tg_token"
            [ -n "$_tg_chat" ] && [ -z "$EDAMAME_TELEGRAM_CHAT_ID" ] && EDAMAME_TELEGRAM_CHAT_ID="$_tg_chat"
            [ -n "$_tg_interactive" ] && [ -z "$EDAMAME_TELEGRAM_INTERACTIVE_ENABLED" ] && EDAMAME_TELEGRAM_INTERACTIVE_ENABLED="$_tg_interactive"
            [ -n "$_tg_users" ] && [ -z "$EDAMAME_TELEGRAM_ALLOWED_USER_IDS" ] && EDAMAME_TELEGRAM_ALLOWED_USER_IDS="$_tg_users"
            if [ -n "$EDAMAME_TELEGRAM_BOT_TOKEN" ] && [ -n "$EDAMAME_TELEGRAM_CHAT_ID" ]; then
                echo "  Loaded Telegram vars from $candidate"
                break
            fi
        fi
    done
fi

# Load Slack vars from slack.env or edamame-llm.env if empty.
# slack.env uses unprefixed names (SLACK_BOT_TOKEN, SLACK_CHANNEL_ID).
if [ -z "$EDAMAME_AGENTIC_SLACK_BOT_TOKEN" ] || [ -z "$EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL" ] || [ -z "$EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL" ]; then
    for candidate in \
        "${SECRETS_DIR:-/nonexistent}/slack.env" \
        "$REPO_DIR/../secrets/slack.env" \
        "${SECRETS_DIR:-/nonexistent}/edamame-llm.env" \
        "$REPO_DIR/../secrets/edamame-llm.env" \
        "$REPO_DIR/../secrets.env"; do
        if [ -f "$candidate" ]; then
            _slack_token=$(bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; echo \"\${SLACK_BOT_TOKEN:-\${EDAMAME_AGENTIC_SLACK_BOT_TOKEN:-\${EDAMAME_AGENTIC_WEBHOOK_ACTIONS_TOKEN:-}}}\"")
            _slack_actions=$(bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; echo \"\${SLACK_CHANNEL_ID:-\${EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL:-\${EDAMAME_AGENTIC_WEBHOOK_ACTIONS_CHANNEL:-}}}\"")
            _slack_escalations=$(bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; echo \"\${EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL:-\${EDAMAME_AGENTIC_WEBHOOK_ESCALATIONS_CHANNEL:-}}\"")
            [ -n "$_slack_token" ] && [ -z "$EDAMAME_AGENTIC_SLACK_BOT_TOKEN" ] && EDAMAME_AGENTIC_SLACK_BOT_TOKEN="$_slack_token"
            [ -n "$_slack_actions" ] && [ -z "$EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL" ] && EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL="$_slack_actions"
            [ -n "$_slack_escalations" ] && [ -z "$EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL" ] && EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL="$_slack_escalations"
            if [ -n "$EDAMAME_AGENTIC_SLACK_BOT_TOKEN" ]; then
                echo "  Loaded Slack vars from $candidate"
                break
            fi
        fi
    done
fi

if [ "$EDAMAME_LLM_PROVIDER" = "openai" ] && [ -z "$EDAMAME_LLM_API_KEY" ]; then
    # Reuse the OpenAI key already loaded for OpenClaw
    if [ -n "${OPENAI_API_KEY:-}" ]; then
        EDAMAME_LLM_API_KEY="$OPENAI_API_KEY"
        echo "  Reusing OpenClaw OPENAI_API_KEY for EDAMAME internal LLM"
    fi
    EDAMAME_LLM_MODEL="${EDAMAME_LLM_MODEL:-gpt-4o-mini}"
fi

if [ "$EDAMAME_LLM_PROVIDER" = "claude" ] && [ -z "$EDAMAME_LLM_API_KEY" ]; then
    for candidate in \
        "${SECRETS_DIR:-/nonexistent}/claude.env" \
        "$REPO_DIR/../secrets/claude.env"; do
        if [ -f "$candidate" ]; then
            _key=$(bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; echo \"\${ANTHROPIC_API_KEY:-\${CLAUDE_API_KEY:-}}\"")
            if [ -n "$_key" ]; then
                EDAMAME_LLM_API_KEY="$_key"
                echo "  Loaded Claude API key from $candidate"
                break
            fi
        fi
    done
    EDAMAME_LLM_MODEL="${EDAMAME_LLM_MODEL:-claude-haiku-4-5-20251001}"
fi

if [ "$EDAMAME_LLM_PROVIDER" = "ollama" ]; then
    EDAMAME_LLM_BASE_URL="${EDAMAME_LLM_BASE_URL:-http://localhost:11434}"
    EDAMAME_LLM_MODEL="${EDAMAME_LLM_MODEL:-llama4}"
fi

case "$EDAMAME_LLM_PROVIDER" in
    edamame|openai|claude)
        if [ -z "$EDAMAME_LLM_API_KEY" ]; then
            echo "  WARNING: No API key found for EDAMAME_LLM_PROVIDER=$EDAMAME_LLM_PROVIDER"
            echo "  The internal divergence engine will run without LLM enrichment."
            echo "  To configure: set EDAMAME_LLM_API_KEY or place credentials in ../secrets/edamame-llm.env"
            EDAMAME_LLM_PROVIDER="none"
        fi
        ;;
esac

echo "  EDAMAME LLM provider: $EDAMAME_LLM_PROVIDER"
[ -n "$EDAMAME_LLM_MODEL" ] && echo "  EDAMAME LLM model: $EDAMAME_LLM_MODEL"
[ -n "$EDAMAME_LLM_BASE_URL" ] && echo "  EDAMAME LLM base URL: $EDAMAME_LLM_BASE_URL"
[ -n "$EDAMAME_TELEGRAM_BOT_TOKEN" ] && echo "  Telegram notifications: enabled (chat_id: $EDAMAME_TELEGRAM_CHAT_ID)"
if [ "$EDAMAME_TELEGRAM_INTERACTIVE_ENABLED" = "true" ] || [ "$EDAMAME_TELEGRAM_INTERACTIVE_ENABLED" = "1" ]; then
    echo "  Telegram interactive (bidirectional): enabled (allowed_user_ids: ${EDAMAME_TELEGRAM_ALLOWED_USER_IDS:-<none>})"
fi
if [ -n "$EDAMAME_AGENTIC_SLACK_BOT_TOKEN" ]; then
    echo "  Slack notifications: enabled (actions: ${EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL:-<none>}, escalations: ${EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL:-<none>})"
fi

# Persist EDAMAME runtime env vars so systemd/manual starts stay in sync.
{
    echo "# EDAMAME runtime configuration (written by provision.sh)"
    echo "EDAMAME_LLM_API_KEY=\"$EDAMAME_LLM_API_KEY\""
    echo "EDAMAME_LLM_MODEL=\"$EDAMAME_LLM_MODEL\""
    echo "EDAMAME_LLM_BASE_URL=\"$EDAMAME_LLM_BASE_URL\""
    echo "EDAMAME_TELEGRAM_BOT_TOKEN=\"$EDAMAME_TELEGRAM_BOT_TOKEN\""
    echo "EDAMAME_TELEGRAM_CHAT_ID=\"$EDAMAME_TELEGRAM_CHAT_ID\""
    echo "EDAMAME_TELEGRAM_INTERACTIVE_ENABLED=\"$EDAMAME_TELEGRAM_INTERACTIVE_ENABLED\""
    echo "EDAMAME_TELEGRAM_ALLOWED_USER_IDS=\"$EDAMAME_TELEGRAM_ALLOWED_USER_IDS\""
    echo "EDAMAME_AGENTIC_SLACK_BOT_TOKEN=\"$EDAMAME_AGENTIC_SLACK_BOT_TOKEN\""
    echo "EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL=\"$EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL\""
    echo "EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL=\"$EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL\""
} | sudo tee /etc/edamame_llm.env >/dev/null
sudo chmod 600 /etc/edamame_llm.env

# Source into current environment for the daemon start below
export EDAMAME_LLM_API_KEY EDAMAME_LLM_MODEL EDAMAME_LLM_BASE_URL
export EDAMAME_TELEGRAM_BOT_TOKEN EDAMAME_TELEGRAM_CHAT_ID EDAMAME_TELEGRAM_INTERACTIVE_ENABLED EDAMAME_TELEGRAM_ALLOWED_USER_IDS
export EDAMAME_AGENTIC_SLACK_BOT_TOKEN EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL

# ──────────────────────────────────────────────
# Step 1b: Ensure runtime dependencies
# ──────────────────────────────────────────────
echo ""
echo "--- Step 1b: Ensuring runtime dependencies ---"

# If a pre-built binary is provided (cross-compilation, local dev, etc.),
# install it directly and skip the APT path.
if [ -n "${EDAMAME_POSTURE_BINARY:-}" ]; then
    if [ -f "$EDAMAME_POSTURE_BINARY" ]; then
        echo "  Installing provided binary: $EDAMAME_POSTURE_BINARY"
        # Install runtime dependencies that the APT package would normally pull in.
        apt_update_once
        apt_install libgtk-3-0 libpcap0.8 libayatana-appindicator3-1 2>/dev/null \
            || apt_install libgtk-3-0 libpcap0.8 || true
        sudo cp "$EDAMAME_POSTURE_BINARY" /usr/local/bin/edamame_posture
        sudo chmod +x /usr/local/bin/edamame_posture
        # Also install to /usr/bin so systemd service finds it on the default PATH.
        sudo cp "$EDAMAME_POSTURE_BINARY" /usr/bin/edamame_posture
        sudo chmod +x /usr/bin/edamame_posture
        # Create systemd service file when APT package is not installed.
        if ! sudo systemctl is-enabled edamame_posture >/dev/null 2>&1; then
            echo "  Creating systemd service for custom binary..."
            sudo tee /etc/systemd/system/edamame_posture.service > /dev/null << 'SVCEOF'
[Unit]
Description=EDAMAME Posture Security Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/local/bin/edamame_posture background-start-disconnected --network-scan --packet-capture --agentic-mode analyze
ExecStartPost=/bin/bash -c 'sleep 5; PSK="$(cat "\$HOME/.edamame_psk" 2>/dev/null || true)"; [ -n "\$PSK" ] && /usr/local/bin/edamame_posture background-mcp-start 3000 "\$PSK" >/dev/null 2>&1 || true'
ExecStop=/usr/local/bin/edamame_posture background-stop
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF
            sudo systemctl daemon-reload
            sudo systemctl enable edamame_posture
        fi
        echo "  Installed: $(edamame_posture --version 2>&1 || echo 'version unknown')"
    else
        echo "ERROR: EDAMAME_POSTURE_BINARY set but file not found: $EDAMAME_POSTURE_BINARY"
        exit 1
    fi
fi

if ! command -v edamame_posture >/dev/null 2>&1; then
    echo "  Installing EDAMAME Posture via APT..."
    if [ ! -f /usr/share/keyrings/edamame.gpg ]; then
        curl -fsSL https://edamame.s3.eu-west-1.amazonaws.com/repo/public.key \
            | sudo gpg --dearmor --yes --batch -o /usr/share/keyrings/edamame.gpg
    fi
    ARCH="$(dpkg --print-architecture)"
    echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/edamame.gpg] https://edamame.s3.eu-west-1.amazonaws.com/repo stable main" \
        | sudo tee /etc/apt/sources.list.d/edamame.list >/dev/null
    # Fast path: refresh only the EDAMAME repo metadata first.
    sudo env DEBIAN_FRONTEND=noninteractive apt-get ${APT_FLAGS} update -y \
        -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/edamame.list \
        -o Dir::Etc::sourceparts="-" \
        -o APT::Get::List-Cleanup="0"
    if ! apt_install edamame-posture; then
        echo "  Targeted install failed; refreshing full apt metadata and retrying..."
        apt_update_once
        apt_install edamame-posture
    fi
fi

# Optional: node may not be installed yet
NODE_VERSION="$(node --version 2>/dev/null || true)"
case "$NODE_VERSION" in
    v22.*) ;;
    *)
        echo "  Installing Node.js 22 (binary distribution)..."
        ARCH_RAW="$(uname -m)"
        case "$ARCH_RAW" in
            aarch64|arm64) NODE_ARCH="arm64" ;;
            x86_64|amd64) NODE_ARCH="x64" ;;
            *)
                echo "ERROR: Unsupported architecture for Node install: $ARCH_RAW"
                exit 1
                ;;
        esac

        NODE_BASE_URL="https://nodejs.org/dist/latest-v22.x"
        NODE_TARBALL="$(curl -fsSL "${NODE_BASE_URL}/SHASUMS256.txt" | awk -v arch="${NODE_ARCH}" '$2 ~ ("linux-" arch "\\.tar\\.xz$") {print $2; exit}')"
        if [ -z "$NODE_TARBALL" ]; then
            echo "ERROR: Could not resolve latest Node.js v22 tarball for ${NODE_ARCH}"
            exit 1
        fi

        TMP_NODE_TAR="/tmp/${NODE_TARBALL}"
        curl -fsSL "${NODE_BASE_URL}/${NODE_TARBALL}" -o "$TMP_NODE_TAR"
        mkdir -p "$HOME/.local"
        tar -xJf "$TMP_NODE_TAR" -C "$HOME/.local"
        NODE_DIR_BASENAME="${NODE_TARBALL%.tar.xz}"
        ln -sfn "$HOME/.local/${NODE_DIR_BASENAME}" "$HOME/.local/node-v22"
        mkdir -p "$HOME/.local/bin"
        ln -sfn "$HOME/.local/node-v22/bin/node" "$HOME/.local/bin/node"
        ln -sfn "$HOME/.local/node-v22/bin/npm" "$HOME/.local/bin/npm"
        ln -sfn "$HOME/.local/node-v22/bin/npx" "$HOME/.local/bin/npx"
        ;;
esac

# ──────────────────────────────────────────────
# Step 2: Start EDAMAME Posture + MCP server
# ──────────────────────────────────────────────
echo ""
echo "--- Step 2: Starting EDAMAME Posture ---"

echo "  Configuring eBPF kernel parameters..."
# Optional: may fail in containers or restricted environments
sudo sysctl -w kernel.perf_event_paranoid=-1 >/dev/null || true
sudo sysctl -w kernel.unprivileged_bpf_disabled=0 >/dev/null || true
sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
if ! sudo test -f /etc/sysctl.d/99-ebpf.conf || ! sudo grep -q "perf_event_paranoid" /etc/sysctl.d/99-ebpf.conf; then
    {
        echo "kernel.perf_event_paranoid=-1"
        echo "kernel.unprivileged_bpf_disabled=0"
    } | sudo tee /etc/sysctl.d/99-ebpf.conf >/dev/null
fi

# Generate PSK for MCP authentication (VM/daemon path).
# Developer workstations with the EDAMAME app should use setup/pair.sh instead.
# IMPORTANT: normalize to a single line (some generators wrap base64 with newlines).
PSK_RAW="$(edamame_posture background-mcp-generate-psk 2>/dev/null || openssl rand -base64 32)"
PSK="$(printf "%s\n" "$PSK_RAW" | awk 'NF && $1 !~ /^#/ { print; exit }')"
if [ -z "$PSK" ]; then
    PSK="$(openssl rand -base64 32 | tr -d '\r\n')"
fi
PSK_FILE="$HOME/.edamame_psk"
printf "%s" "$PSK" > "$PSK_FILE"
chmod 600 "$PSK_FILE"
echo "  PSK generated and saved to $PSK_FILE"

# Configure /etc/edamame_posture.conf so the systemd service starts with the
# right flags. The daemon provides telemetry collection AND runs the internal
# divergence engine when an LLM provider is configured.
#
# NOTE: Session/anomaly evidence requires packet capture. Without it, the
# network/session endpoints return empty output and the two-plane demo cannot
# prove intent-vs-network divergence.
echo "  Configuring /etc/edamame_posture.conf..."

sudo EDAMAME_LLM_API_KEY="$EDAMAME_LLM_API_KEY" python3 -c "
import re, sys, os
conf_path = '/etc/edamame_posture.conf'
try:
    text = open(conf_path).read()
except FileNotFoundError:
    print('  WARNING: conf file not found, skipping config')
    sys.exit(0)
llm_key = os.environ.get('EDAMAME_LLM_API_KEY', '')
replacements = {
    'start_capture': 'true',
    'start_lanscan': 'false',
    'agentic_mode': 'analyze',
    'llm_api_key': llm_key,
}
for key, val in replacements.items():
    text = re.sub(
        rf'^({key}:\s*)\".*?\"',
        rf'\1\"{val}\"',
        text,
        flags=re.MULTILINE,
    )
with open(conf_path, 'w') as f:
    f.write(text)
provider = 'edamame' if llm_key else 'none'
print(f'  Config updated: capture=true, lanscan=false, agentic_mode=analyze, provider={provider}')
" 2>&1

# Tune kernel networking limits so the port scanner's concurrent SYN_SENT
# connections don't starve other outbound traffic in the Lima VM.
echo "  Tuning kernel network and FD limits..."
sudo tee /etc/sysctl.d/99-edamame.conf >/dev/null <<'SYSEOF'
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.core.somaxconn = 8192
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1048576
SYSEOF
sudo sysctl -p /etc/sysctl.d/99-edamame.conf >/dev/null 2>&1

sudo tee /etc/security/limits.d/99-edamame.conf >/dev/null <<'LIMEOF'
*    soft    nofile    65536
*    hard    nofile    65536
root soft    nofile    65536
root hard    nofile    65536
LIMEOF

# Inject EDAMAME LLM env vars into the systemd service environment so the
# daemon process can read them (EDAMAME_LLM_API_KEY, etc.).
if command -v systemctl >/dev/null 2>&1 && sudo systemctl is-enabled edamame_posture >/dev/null 2>&1; then
    echo "  Injecting EDAMAME LLM env and FD limits into systemd override..."
    sudo mkdir -p /etc/systemd/system/edamame_posture.service.d
    {
        echo "[Service]"
        echo "EnvironmentFile=/etc/edamame_llm.env"
        echo "LimitNOFILE=65536"
    } | sudo tee /etc/systemd/system/edamame_posture.service.d/edamame.conf >/dev/null
    sudo systemctl daemon-reload
fi

# Clear persisted LAN scan auto_scan state so the daemon doesn't
# restart scanning from a stale cache (Lima VM can't handle it).
sudo rm -f /root/.local/share/*.json 2>/dev/null || true

echo "  Restarting daemon with updated config..."
if command -v systemctl >/dev/null 2>&1 && sudo systemctl is-enabled edamame_posture >/dev/null 2>&1; then
    sudo systemctl restart edamame_posture
else
    sudo -E edamame_posture background-start-disconnected \
        --packet-capture \
        --agentic-provider edamame \
        --agentic-mode analyze 2>&1
fi

echo "  Waiting for daemon initialization (20s)..."
sleep 20

# Verify daemon is running
echo "  Daemon status:"
if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl is-active edamame_posture 2>/dev/null | sed -n "1,1p" || true
else
    ps aux | grep "[e]damame_posture" | head -1 || echo "  (pending)"
fi

# Disable LAN auto-scan to prevent network saturation in Lima VM.
# The daemon defaults auto_scan=true but Lima's socket_vmnet cannot
# handle the SYN flood from port scanning across all gateway subnets.
echo "  Disabling LAN auto-scan..."
PSK_FILE="$HOME/.edamame_psk"
if [ -f "$PSK_FILE" ] && [ -f /tmp/mcp_call.py ]; then
    python3 /tmp/mcp_call.py set_lan_auto_scan '{"enabled": false}' 2>/dev/null || true
elif [ -f "$PSK_FILE" ]; then
    PSK=$(cat "$PSK_FILE")
    python3 -c "
import json, urllib.request
url = 'http://127.0.0.1:3000/mcp'
body = json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'set_lan_auto_scan','arguments':{'enabled':False}}}).encode()
req = urllib.request.Request(url, data=body, headers={'Content-Type':'application/json','Authorization':'Bearer $PSK'})
try:
    urllib.request.urlopen(req, timeout=10)
    print('  LAN auto-scan disabled')
except Exception as e:
    print(f'  Warning: could not disable auto-scan: {e}')
" 2>/dev/null || true
fi

# Verify eBPF is active (critical for L7 process attribution accuracy)
echo "  eBPF status:"
if command -v journalctl >/dev/null 2>&1; then
    EBPF_MSG=$(sudo journalctl -u edamame_posture --no-pager -n 200 2>/dev/null \
        | grep -i "eBPF" | tail -1 || true)
    if echo "$EBPF_MSG" | grep -qi "initialised successfully"; then
        echo "  eBPF ACTIVE: $EBPF_MSG"
    elif [ -n "$EBPF_MSG" ]; then
        echo "  WARNING: eBPF may not be active: $EBPF_MSG"
    else
        echo "  WARNING: no eBPF status found in daemon logs"
    fi
else
    echo "  (journalctl not available; cannot verify eBPF status)"
fi

# Start MCP server on port 3000 with PSK auth
echo ""
echo "  Starting MCP server on port 3000..."
sudo edamame_posture background-mcp-start 3000 "$PSK" 2>&1
sleep 3

echo "  MCP health:"
# Optional: health probe; service may still be starting
curl -s -m 2 http://127.0.0.1:3000/health 2>&1 || echo "  (health pending)"

# Sync PSK from daemon internal config (authoritative source after MCP start).
# The daemon may have regenerated its own PSK via systemd auto-start or internal
# state, so always re-read from the daemon's config to stay in sync.
DAEMON_PSK=""
if sudo test -f /root/.edamame/mcp_server_config.json; then
    DAEMON_PSK=$(sudo python3 -c "import json; print(json.load(open('/root/.edamame/mcp_server_config.json')).get('psk',''))" 2>/dev/null)
fi
if [ -n "$DAEMON_PSK" ]; then
    printf "%s" "$DAEMON_PSK" > "$PSK_FILE"
    chmod 600 "$PSK_FILE"
    echo "  PSK re-synced from daemon config (authoritative)."
fi

# Register demo identity for HIBP breach monitoring via MCP
echo ""
echo "  Registering demo identity (john@acme.com) for breach monitoring..."
DEMO_IDENTITY="john@acme.com"
# Optional: PSK file may not exist yet
CURRENT_PSK="$(cat "$PSK_FILE" 2>/dev/null || true)"
if [ -n "$CURRENT_PSK" ]; then
    # Optional: MCP may not be ready; demo identity registration is best-effort
    curl -sS -m 15 http://127.0.0.1:3000/mcp \
        -H "Authorization: Bearer $CURRENT_PSK" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"provision\",\"version\":\"1.0\"}}}" > /dev/null 2>&1 || true
    sleep 1
    # Optional: add_pwned_email may fail if MCP not ready; demo-only
    ADD_RESP="$(curl -sS -m 30 http://127.0.0.1:3000/mcp \
        -H "Authorization: Bearer $CURRENT_PSK" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"add_pwned_email\",\"arguments\":{\"email\":\"$DEMO_IDENTITY\"}}}" 2>&1 || true)"
    echo "  add_pwned_email response: $ADD_RESP"
else
    echo "  WARNING: No PSK available, skipping breach identity registration"
fi

# Enable LAN auto-scan via MCP
echo "  Enabling LAN auto-scan..."
if [ -n "$CURRENT_PSK" ]; then
    # Optional: set_lan_auto_scan may fail if MCP not ready
    curl -sS -m 15 http://127.0.0.1:3000/mcp \
        -H "Authorization: Bearer $CURRENT_PSK" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"set_lan_auto_scan\",\"arguments\":{\"enabled\":true}}}" > /dev/null 2>&1 || true
    echo "  LAN auto-scan enabled"
fi

# Enable the vulnerability detector (model-independent, always safe to start)
echo "  Enabling vulnerability detector (interval=120s)..."
edamame_posture vulnerability-start 120 > /dev/null 2>&1 || true
echo "  Vulnerability detector enabled (2-minute cycle)"

# Enable the internal divergence engine via CLI (if LLM provider is configured)
if [ "$EDAMAME_LLM_PROVIDER" != "none" ]; then
    echo "  Enabling internal divergence engine (interval=120s)..."
    edamame_posture divergence-start 120 > /dev/null 2>&1 || true
    echo "  Divergence engine enabled (2-minute cycle)"
fi

# ──────────────────────────────────────────────
# Step 3: Configure OpenClaw
# ──────────────────────────────────────────────
echo ""
echo "--- Step 3: Configuring OpenClaw ---"

export PATH="$HOME/.npm-global/bin:$PATH"

# Install OpenClaw on-demand. Keeping this here (instead of cloud-init user
# provisioning) makes first-boot VM startup deterministic and avoids long
# cloud-init stalls.
if ! command -v openclaw >/dev/null 2>&1; then
    echo "  OpenClaw missing; installing via npm..."
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"
    export PATH="$HOME/.npm-global/bin:$PATH"
    # Network to npm registry can be flaky in CI/VM environments.
    # Retry with backoff to avoid failing the whole provisioning on transient resets.
    npm config set fetch-retries 8
    npm config set fetch-retry-factor 2
    npm config set fetch-retry-mintimeout 10000
    npm config set fetch-retry-maxtimeout 120000
    npm config set registry "https://registry.npmjs.org/"

    OPENCLAW_INSTALL_OK=0
    for attempt in 1 2 3 4; do
        echo "  npm install attempt ${attempt}/4..."
        if npm install -g openclaw --no-audit --no-fund; then
            OPENCLAW_INSTALL_OK=1
            break
        fi
        sleep $((attempt * 10))
    done

    if [ "$OPENCLAW_INSTALL_OK" -ne 1 ]; then
        echo "ERROR: npm install -g openclaw failed after retries."
        exit 1
    fi
fi

if ! command -v openclaw >/dev/null 2>&1; then
    echo "ERROR: OpenClaw install failed (binary not found in PATH)."
    exit 1
fi

OPENCLAW_DIR="$HOME/.openclaw"
mkdir -p "$OPENCLAW_DIR/agents/main/sessions"
mkdir -p "$OPENCLAW_DIR/credentials"
chmod 700 "$OPENCLAW_DIR/credentials"

# Preserve any pre-existing memorySearch configuration so provisioning
# does not override user intent.
EXISTING_MEMORY_SEARCH_JSON="$(python3 - <<'PY'
import json
import os

p = os.path.expanduser("~/.openclaw/openclaw.json")
if not os.path.exists(p):
    raise SystemExit(0)
try:
    cfg = json.load(open(p, "r", encoding="utf-8"))
except Exception:
    raise SystemExit(0)
ms = cfg.get("agents", {}).get("defaults", {}).get("memorySearch")
if isinstance(ms, dict):
    print(json.dumps(ms))
PY
)"

# Write OpenClaw config
# EDAMAME MCP tools are exposed to the agent as native OpenClaw tools via the
# local `edamame` OpenClaw plugin (installed below).
if [ "$MODEL_PROVIDER" = "openai" ]; then
cat > "$OPENCLAW_DIR/openclaw.json" << EOJSON
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "openai/$OPENAI_PRIMARY_MODEL"
      },
      "models": {
        "openai/$OPENAI_PRIMARY_MODEL": {}
      },
      "memorySearch": {
        "enabled": false
      },
      "workspace": "$HOME/.openclaw/workspace",
      "compaction": {
        "mode": "safeguard"
      },
      "maxConcurrent": 4,
      "subagents": {
        "maxConcurrent": 8
      }
    },
    "list": [
      {
        "id": "main",
        "default": true,
        "identity": {
          "name": "SecurityBot",
          "theme": "security-focused AI assistant monitoring endpoint posture via EDAMAME"
        }
      }
    ]
  },
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "loopback",
    "auth": {
      "mode": "token"
    },
    "controlUi": {
      "enabled": true
    }
  },
  "env": {
    "OPENAI_API_KEY": "$OPENAI_API_KEY"
  }
}
EOJSON
else
cat > "$OPENCLAW_DIR/openclaw.json" << EOJSON
{
  "models": {
    "providers": {
      "azure-openai-responses": {
        "baseUrl": "$FOUNDRY_BASE_URL",
        "apiKey": "$FOUNDRY_API_KEY",
        "api": "openai-responses",
        "authHeader": false,
        "headers": {
          "api-key": "$FOUNDRY_API_KEY"
        },
        "models": [
          {
            "id": "$FOUNDRY_PRIMARY_MODEL",
            "name": "Azure OpenAI ($FOUNDRY_PRIMARY_MODEL)",
            "reasoning": false,
            "input": ["text", "image"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": $FOUNDRY_CONTEXT_WINDOW,
            "maxTokens": $FOUNDRY_MAX_TOKENS,
            "compat": { "supportsStore": false }
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "azure-openai-responses/$FOUNDRY_PRIMARY_MODEL"
      },
      "models": {
        "azure-openai-responses/$FOUNDRY_PRIMARY_MODEL": {}
      },
      "memorySearch": {
        "enabled": false
      },
      "workspace": "$HOME/.openclaw/workspace",
      "compaction": {
        "mode": "safeguard"
      },
      "maxConcurrent": 4,
      "subagents": {
        "maxConcurrent": 8
      }
    },
    "list": [
      {
        "id": "main",
        "default": true,
        "identity": {
          "name": "SecurityBot",
          "theme": "security-focused AI assistant monitoring endpoint posture via EDAMAME"
        }
      }
    ]
  },
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "loopback",
    "auth": {
      "mode": "token"
    },
    "controlUi": {
      "enabled": true
    }
  }
}
EOJSON
fi

if [ -n "$EXISTING_MEMORY_SEARCH_JSON" ]; then
    EXISTING_MEMORY_SEARCH_JSON="$EXISTING_MEMORY_SEARCH_JSON" \
        python3 - "$OPENCLAW_DIR/openclaw.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
cfg = json.load(open(path, "r", encoding="utf-8"))
ms = json.loads(os.environ["EXISTING_MEMORY_SEARCH_JSON"])
cfg.setdefault("agents", {}).setdefault("defaults", {})["memorySearch"] = ms
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
    echo "  Preserved existing memorySearch configuration"
fi

chmod 600 "$OPENCLAW_DIR/openclaw.json"
echo "  OpenClaw config written"

# Write OPENAI_API_KEY to ~/.openclaw/.env for memory search embeddings.
# When using Foundry for the LLM, we still need an OpenAI key for embeddings.
OPENAI_KEY_FOR_EMBEDDINGS=""
if [ -n "${OPENAI_API_KEY:-}" ]; then
    OPENAI_KEY_FOR_EMBEDDINGS="$OPENAI_API_KEY"
else
    for candidate in "$REPO_DIR/../secrets/openai.env" "$REPO_DIR/../secrets.env"; do
        if [ -f "$candidate" ]; then
            _key=$(bash -lc "set -a; source \"$candidate\" >/dev/null 2>&1; echo \"\${OPENAI_API_KEY:-}\"")
            if [ -n "$_key" ]; then
                OPENAI_KEY_FOR_EMBEDDINGS="$_key"
                break
            fi
        fi
    done
fi
if [ -n "$OPENAI_KEY_FOR_EMBEDDINGS" ]; then
    touch "$OPENCLAW_DIR/.env"
    if grep -q '^OPENAI_API_KEY=' "$OPENCLAW_DIR/.env" 2>/dev/null; then
        sed -i "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=$OPENAI_KEY_FOR_EMBEDDINGS|" "$OPENCLAW_DIR/.env"
    else
        printf "OPENAI_API_KEY=%s\n" "$OPENAI_KEY_FOR_EMBEDDINGS" >> "$OPENCLAW_DIR/.env"
    fi
    chmod 600 "$OPENCLAW_DIR/.env"
    echo "  OPENAI_API_KEY written to ~/.openclaw/.env (memory search embeddings)"
else
    echo "  WARNING: No OPENAI_API_KEY found; memory search will use FTS-only fallback."
    echo "  To enable semantic search: add OPENAI_API_KEY to ~/.openclaw/.env"
fi

# Run doctor to validate and fix config (optional fix; non-fatal if config is already valid)
openclaw doctor --fix --yes 2>&1 || true

# ──────────────────────────────────────────────
# Step 4: Install OpenClaw plugin (EDAMAME MCP tools)
# ──────────────────────────────────────────────
echo ""
echo "--- Step 4: Installing OpenClaw plugin (edamame) ---"

PLUGIN_SRC="$REPO_DIR/extensions/edamame"
PLUGIN_DST="$OPENCLAW_DIR/extensions/edamame"
mkdir -p "$PLUGIN_DST"
if [ -f "$PLUGIN_SRC/openclaw.plugin.json" ] && [ -f "$PLUGIN_SRC/index.ts" ]; then
    cp "$PLUGIN_SRC/openclaw.plugin.json" "$PLUGIN_DST/openclaw.plugin.json"
    cp "$PLUGIN_SRC/index.ts" "$PLUGIN_DST/index.ts"
    if grep -q "active_only" "$PLUGIN_DST/index.ts" && grep -q "since" "$PLUGIN_DST/index.ts"; then
        echo "  edamame plugin files installed (get_sessions wrapper filters enabled)"
    else
        echo "  WARNING: edamame plugin installed, but get_sessions wrapper filters were not detected"
    fi
    # Enable it in config (safe to re-run)
    openclaw plugins enable edamame 2>&1
    # If gateway is already running (re-provision path), reload extension code now.
    if ss -tln 2>/dev/null | grep -q ':18789 '; then
        if openclaw gateway restart >/tmp/openclaw-gateway-restart.log 2>&1; then
            echo "  Gateway restarted to load latest edamame plugin"
        else
            echo "  WARNING: gateway restart failed after plugin sync"
        fi
    fi
else
    echo "  WARNING: edamame plugin not found at $PLUGIN_SRC"
fi

# Write alert delivery config for the send_alert tool (plugin reads these files)
if [ -n "$ALERT_TO" ]; then
    printf "%s" "$ALERT_TO" > "$HOME/.openclaw_alert_to"
    chmod 600 "$HOME/.openclaw_alert_to"
    printf "%s" "$ALERT_CHANNEL" > "$HOME/.openclaw_alert_channel"
    chmod 600 "$HOME/.openclaw_alert_channel"
    echo "  Alert delivery configured: channel=$ALERT_CHANNEL, to=$ALERT_TO"
    echo "  Skills will send alerts only when actionable conditions are detected."
else
    echo "  No ALERT_TO set; skills will run silently (verdicts available via get_divergence_verdict)."
    echo "  To enable alerts: ALERT_TO=+33... ./provision.sh"
fi

# ──────────────────────────────────────────────
# Step 5: Install OpenClaw skills
# ──────────────────────────────────────────────
echo ""
echo "--- Step 5: Installing skills ---"

# Extrapolator (session history -> behavioral predictions)
SKILL_EX_SRC="$REPO_DIR/skill/edamame-extrapolator"
SKILL_EX_DST="$OPENCLAW_DIR/skills/edamame-extrapolator"
SKILL_EX_ALIAS_DST="$OPENCLAW_DIR/skills/edamame-cortex-extrapolator"
mkdir -p "$SKILL_EX_DST"
if [ -f "$SKILL_EX_SRC/SKILL.md" ]; then
    cp "$SKILL_EX_SRC/SKILL.md" "$SKILL_EX_DST/SKILL.md"
    rm -rf "$SKILL_EX_ALIAS_DST"
    mkdir -p "$SKILL_EX_ALIAS_DST"
    cp "$SKILL_EX_SRC/SKILL.md" "$SKILL_EX_ALIAS_DST/SKILL.md"
    echo "  edamame-extrapolator installed"
    echo "  edamame-cortex-extrapolator compatibility copy installed"
else
    echo "  WARNING: SKILL.md not found at $SKILL_EX_SRC"
fi

# Cleanup: keep only the current EDAMAME skill set.
for stale_skill in "$OPENCLAW_DIR"/skills/edamame-*; do
    [ -d "$stale_skill" ] || continue
    stale_name="$(basename "$stale_skill")"
    case "$stale_name" in
        edamame-extrapolator|edamame-cortex-extrapolator|edamame-posture) ;;
        *)
            rm -rf "$stale_skill"
            echo "  Removed stale $stale_name skill"
            ;;
    esac
done

# EDAMAME Posture MCP facade skill (thin tool exposure)
SKILL3_SRC="$REPO_DIR/skill/edamame-posture"
SKILL3_DST="$OPENCLAW_DIR/skills/edamame-posture"
mkdir -p "$SKILL3_DST"
if [ -f "$SKILL3_SRC/SKILL.md" ]; then
    cp "$SKILL3_SRC/SKILL.md" "$SKILL3_DST/SKILL.md"
    echo "  edamame-posture installed"
else
    echo "  WARNING: SKILL.md not found at $SKILL3_SRC"
fi

# Helper functions for test/demo cron reconfiguration
reconfigure_cron_fast() {
    # Optional: cron jobs may not exist in fresh install; used by tests/demos
    echo "  Reconfiguring extrapolator cron to */1 for fast feedback..."
    openclaw cron update --name "Cortex Extrapolator" \
        --cron "*/1 * * * *" --exact 2>&1 || true
}

restore_cron_production() {
    # Optional: cron jobs may not exist; used by tests/demos
    # Compiled mode: */1 (cheap). LLM mode: */5 (token cost).
    local mode="${EXTRAPOLATOR_MODE:-compiled}"
    if [ "$mode" = "compiled" ]; then
        echo "  Restoring extrapolator cron to */1 (production, compiled)..."
        openclaw cron update --name "Cortex Extrapolator" \
            --cron "*/1 * * * *" --exact 2>&1 || true
    else
        echo "  Restoring extrapolator cron to */5 (production, llm)..."
        openclaw cron update --name "Cortex Extrapolator" \
            --cron "*/5 * * * *" --exact 2>&1 || true
    fi
}

# Remove cron by name with compatibility for older OpenClaw CLI versions
# that only support `openclaw cron rm <id>`.
remove_cron_by_name_compat() {
    local cron_name="$1"

    if openclaw cron remove --name "$cron_name" >/dev/null 2>&1; then
        echo "  Removed cron '$cron_name'"
        return 0
    fi

    local cron_ids
    cron_ids="$(openclaw cron list --json 2>/dev/null | python3 - "$cron_name" <<'PY'
import json
import sys

name = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

for job in payload.get("jobs", []):
    if (job.get("name") or "").strip() == name and job.get("id"):
        print(job["id"])
PY
)"

    if [ -z "$cron_ids" ]; then
        return 0
    fi

    while IFS= read -r cron_id; do
        [ -n "$cron_id" ] || continue
        openclaw cron rm "$cron_id" >/dev/null 2>&1 || \
            openclaw cron remove "$cron_id" >/dev/null 2>&1 || true
        echo "  Removed cron '$cron_name' (id: $cron_id)"
    done <<< "$cron_ids"
}

# Remove legacy OpenClaw-side jobs from the old two-skill architecture.
remove_cron_by_name_compat "Divergence Detector"
remove_cron_by_name_compat "Posture Security Check"
remove_cron_by_name_compat "Extrapolator"
remove_cron_by_name_compat "Cortex Extrapolator"

# Register extrapolator cron (reads session history, writes behavioral model).
#
# EXTRAPOLATOR_MODE selects how the cron job runs:
#   compiled  (default) - Calls extrapolator_run_cycle plugin tool. Zero
#                         OpenClaw agent LLM tokens. EDAMAME's internal
#                         LLM handles behavioral model generation.
#   llm                 - Full agent runbook (LLM-driven). Uses the OpenClaw
#                         agent LLM to read transcripts and build the model.
#
EXTRAPOLATOR_MODE="${EXTRAPOLATOR_MODE:-compiled}"
OPENCLAW_AGENT_INSTANCE_ID="$(edamame_openclaw_resolve_agent_instance_id "${AGENT_INSTANCE_ID:-}")"
echo "  Registering extrapolator cron job (mode: $EXTRAPOLATOR_MODE)..."
echo "  Stable agent instance ID: $OPENCLAW_AGENT_INSTANCE_ID"
echo "  Stable ID file: $(edamame_openclaw_agent_instance_id_file)"

case "$EXTRAPOLATOR_MODE" in
    compiled)
        # Compiled mode is cheap (zero OpenClaw LLM tokens), run every minute.
        openclaw cron add \
            --name "Cortex Extrapolator" \
            --cron "*/1 * * * *" \
            --exact \
            --session isolated \
            --light-context \
            --timeout 600000 \
            --timeout-seconds 600 \
            --thinking off \
            --message "Call extrapolator_run_cycle with active_minutes=5 and agent_instance_id=$OPENCLAW_AGENT_INSTANCE_ID. Report the JSON result. If it fails, fall back to the edamame-extrapolator SKILL.md Mode B runbook." \
            --no-deliver 2>&1 || echo "  (cron job may already exist)"
        echo "  Extrapolator cron registered (*/1 production, mode=compiled)"
        ;;
    llm)
        # LLM mode consumes OpenClaw agent tokens, run every 5 minutes.
        openclaw cron add \
            --name "Cortex Extrapolator" \
            --cron "*/5 * * * *" \
            --exact \
            --session isolated \
            --light-context \
            --timeout 600000 \
            --timeout-seconds 600 \
            --thinking off \
            --message "Run extrapolation. This message is authoritative; do not read SKILL.md. Read MEMORY.md but use only the ## [extrapolator] State section and ignore any legacy [cortex-extrapolator] or [expected-behavior] sections. Call sessions_list activeMinutes=15, then sessions_history includeTools=true limit=100 for sessions with new activity. Build a V3 upsert_behavioral_model window_json with top-level fields window_start, window_end, agent_type, agent_instance_id, predictions, contributors, version, hash, ingested_at. Each prediction must be an object with agent_type, agent_instance_id, session_key, action, tools_called, expected_traffic, expected_sensitive_files, expected_lan_devices, expected_local_open_ports, expected_process_paths, expected_parent_paths, expected_open_files, expected_l7_protocols, expected_system_config, not_expected_traffic, not_expected_sensitive_files, not_expected_lan_devices, not_expected_local_open_ports, not_expected_process_paths, not_expected_parent_paths, not_expected_open_files, not_expected_l7_protocols, not_expected_system_config. Use agent_type=openclaw, agent_instance_id=$OPENCLAW_AGENT_INSTANCE_ID, contributors=[], version=3.0, hash=\"\", and arrays not objects. Do not derive, mutate, or append to agent_instance_id. After upsert_behavioral_model, call get_behavioral_model and retry until the result is non-null, has predictions, and includes your contributor identity. Update only the ## [extrapolator] State checkpoint in MEMORY.md with last_analysis_ts, cycles_completed, and analyzed_sessions; do not write an [expected-behavior] section. Print EXTRAPOLATOR_DONE: <N> sessions processed, behavioral model upserted only after read-back succeeds." \
            --no-deliver 2>&1 || echo "  (cron job may already exist)"
        echo "  Extrapolator cron registered (*/5 production, mode=llm)"
        ;;
    *)
        echo "ERROR: EXTRAPOLATOR_MODE must be 'compiled' or 'llm'"
        exit 1
        ;;
esac

# ──────────────────────────────────────────────
# Step 6: Start OpenClaw gateway
# ──────────────────────────────────────────────
echo ""
echo "--- Step 6: Starting OpenClaw gateway ---"

# Optional: doctor fix; gateway will start regardless
openclaw doctor --fix --yes 2>/dev/null || true

# Prefer systemd service for reliability; fall back to foreground nohup.
if command -v systemctl >/dev/null 2>&1; then
    openclaw gateway install 2>/dev/null || true
    openclaw gateway start 2>&1 || true
else
    nohup openclaw gateway run --port 18789 > /tmp/openclaw-gateway.log 2>&1 &
fi
sleep 10
openclaw status 2>/dev/null | head -20 || echo "  OpenClaw starting..."

# ──────────────────────────────────────────────
# Step 7: Verify OpenClaw-native EDAMAME tools
# ──────────────────────────────────────────────
echo ""
echo "--- Step 7: Verifying OpenClaw-native EDAMAME tools ---"

# Optional: config may not have gateway token yet
TOKEN="$(python3 - <<'PY' 2>/dev/null || true
import json, os
p=os.path.expanduser("~/.openclaw/openclaw.json")
cfg=json.load(open(p,"r",encoding="utf-8"))
print(cfg.get("gateway",{}).get("auth",{}).get("token",""))
PY
)"

if [ -z "$TOKEN" ]; then
    echo "  WARNING: Gateway token missing; cannot verify tools/invoke"
else
    RESP="$(curl -sS -m 20 http://127.0.0.1:18789/tools/invoke \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"tool":"advisor_get_todos","args":{}}' || true)"
    if python3 - "$RESP" <<'PY' >/dev/null 2>&1; then
import json, sys
obj=json.loads(sys.argv[1] or "{}")
assert obj.get("ok") is True
PY
        echo "  OpenClaw-native MCP tool path: OK"
    else
        echo "  WARNING: OpenClaw-native MCP tool path: FAILED"
        echo "  Response: $RESP"
    fi
fi

# ──────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Provisioning Complete!"
echo "============================================"
echo ""
echo "  EDAMAME Score (MCP): get_score"
echo "  EDAMAME MCP:        http://127.0.0.1:3000/mcp (PSK in ~/.edamame_psk)"
echo "  OpenClaw Dashboard: http://127.0.0.1:18789/"
echo ""
echo "  EDAMAME Internal LLM:"
echo "    Provider: $EDAMAME_LLM_PROVIDER"
if [ "$EDAMAME_LLM_PROVIDER" != "none" ]; then
echo "    Divergence engine: ENABLED (2-minute cycle)"
else
echo "    Divergence engine: DISABLED (no LLM configured)"
fi
echo "    To change provider: EDAMAME_LLM_PROVIDER=foundry|openai|claude|ollama|edamame"
echo ""
echo "  Extrapolator (session history -> behavioral predictions):"
echo "    Mode: $EXTRAPOLATOR_MODE (compiled=zero LLM tokens, llm=full agent runbook)"
echo "    Override: EXTRAPOLATOR_MODE=llm ./provision.sh"
echo "    openclaw agent --local --agent main -m 'Run extrapolation'"
echo ""
echo "  EDAMAME Posture MCP facade (on-demand tool exposure):"
echo "    openclaw agent --local --agent main -m 'Use edamame-posture to show score and active todos'"
echo ""
echo "  Cron Jobs (periodic via openclaw cron):"
echo "    openclaw cron list                    # view scheduled jobs"
echo "    openclaw cron run <job-id>            # force immediate run"
if [ "$EXTRAPOLATOR_MODE" = "compiled" ]; then
echo "    Extrapolator:  */1 * * * * (compiled, zero LLM tokens)"
else
echo "    Extrapolator:  */5 * * * * (llm, agent runbook)"
fi
echo ""
