#!/usr/bin/env bash
# pair.sh -- App-mediated pairing for developer workstations.
#
# Sends a pairing request to the EDAMAME Security app's MCP endpoint,
# waits for the user to approve in the app, then stores the issued
# credential in ~/.edamame_psk.
#
# For VM/daemon environments, use provision.sh instead (PSK flow).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./agent_identity.sh
source "$SCRIPT_DIR/agent_identity.sh"

PAIR_ENDPOINT="${PAIR_ENDPOINT:-http://127.0.0.1:3000}"
AGENT_TYPE="${AGENT_TYPE:-openclaw}"
AGENT_INSTANCE_ID="${AGENT_INSTANCE_ID:-}"
CLIENT_NAME="${CLIENT_NAME:-OpenClaw EDAMAME Plugin}"
PSK_FILE="${PSK_FILE:-$HOME/.edamame_psk}"
POLL_INTERVAL=2
TIMEOUT=60

usage() {
  cat <<EOF
Usage: pair.sh [OPTIONS]

Request app-mediated pairing with the EDAMAME Security app.

Options:
  --endpoint URL          EDAMAME MCP base URL (default: http://127.0.0.1:3000)
  --agent-type TYPE       Agent type identifier (default: openclaw)
  --agent-instance-id ID  Agent instance ID (default: persisted stable deployment ID)
  --client-name NAME      Display name (default: OpenClaw EDAMAME Plugin)
  --psk-file PATH         Where to store the credential (default: ~/.edamame_psk)
  --timeout SECONDS       How long to wait for approval (default: 60)
  -h, --help              Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) PAIR_ENDPOINT="$2"; shift 2;;
    --agent-type) AGENT_TYPE="$2"; shift 2;;
    --agent-instance-id) AGENT_INSTANCE_ID="$2"; shift 2;;
    --client-name) CLIENT_NAME="$2"; shift 2;;
    --psk-file) PSK_FILE="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

AGENT_INSTANCE_ID="$(edamame_openclaw_resolve_agent_instance_id "$AGENT_INSTANCE_ID")"
PAIR_URL="${PAIR_ENDPOINT}/mcp/pair"

echo "Requesting pairing with EDAMAME Security app..."
echo "  Endpoint: ${PAIR_ENDPOINT}"
echo "  Agent:    ${AGENT_TYPE} / ${AGENT_INSTANCE_ID}"
echo "  ID file:  $(edamame_openclaw_agent_instance_id_file)"

RESPONSE=$(curl -sf -X POST "${PAIR_URL}" \
  -H "Content-Type: application/json" \
  -d "{
    \"client_name\": \"${CLIENT_NAME}\",
    \"agent_type\": \"${AGENT_TYPE}\",
    \"agent_instance_id\": \"${AGENT_INSTANCE_ID}\",
    \"requested_endpoint\": \"${PAIR_ENDPOINT}/mcp\",
    \"workspace_hint\": null
  }" 2>&1) || {
  echo "Failed to reach EDAMAME MCP endpoint at ${PAIR_URL}" >&2
  echo "Make sure the EDAMAME Security app is running with MCP enabled." >&2
  exit 1
}

REQUEST_ID=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('request_id',''))" 2>/dev/null || echo "")

if [[ -z "${REQUEST_ID}" ]]; then
  echo "Failed to create pairing request." >&2
  echo "Response: ${RESPONSE}" >&2
  exit 1
fi

echo ""
echo "Approve the pairing request in the EDAMAME Security app..."
echo "  Request ID: ${REQUEST_ID}"
echo ""

DEADLINE=$(($(date +%s) + TIMEOUT))

while [[ $(date +%s) -lt ${DEADLINE} ]]; do
  sleep ${POLL_INTERVAL}

  STATUS_RESPONSE=$(curl -sf "${PAIR_URL}/${REQUEST_ID}" 2>/dev/null || echo '{}')
  STATUS=$(echo "${STATUS_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

  case "${STATUS}" in
    approved)
      CREDENTIAL=$(echo "${STATUS_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('credential',''))" 2>/dev/null || echo "")
      if [[ -z "${CREDENTIAL}" ]]; then
        echo "Approved but no credential received (already consumed?)." >&2
        exit 1
      fi

      mkdir -p "$(dirname "${PSK_FILE}")"
      echo "${CREDENTIAL}" > "${PSK_FILE}"
      chmod 600 "${PSK_FILE}"

      echo "Pairing approved. Credential stored in ${PSK_FILE}"

      # Verify connectivity
      echo "Verifying connection..."
      HEALTH=$(curl -sf "${PAIR_ENDPOINT}/health" 2>/dev/null || echo "")
      if [[ "${HEALTH}" == "OK" ]]; then
        echo "Connection verified."
      else
        echo "Warning: health check did not return OK." >&2
      fi
      exit 0
      ;;
    rejected)
      echo "Pairing rejected by user." >&2
      exit 1
      ;;
    expired)
      echo "Pairing request expired." >&2
      exit 1
      ;;
    pending)
      printf "."
      ;;
    *)
      ;;
  esac
done

echo ""
echo "Pairing timed out after ${TIMEOUT} seconds." >&2
echo "Try again or use the PSK method for manual pairing." >&2
exit 1
