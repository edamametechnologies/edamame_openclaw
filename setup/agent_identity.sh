#!/usr/bin/env bash

# Shared OpenClaw deployment identity helpers.
#
# The EDAMAME/OpenClaw contract requires one stable agent_instance_id per
# OpenClaw deployment. We persist that ID in a single-line file so pairing,
# provisioning, cron prompts, and plugin tool calls all converge on the same
# identity instead of deriving it independently.

EDAMAME_OPENCLAW_AGENT_INSTANCE_ID_FILE_DEFAULT="${HOME}/.edamame_openclaw_agent_instance_id"

edamame_openclaw_agent_instance_id_file() {
    printf '%s\n' "${EDAMAME_OPENCLAW_AGENT_INSTANCE_ID_FILE:-$EDAMAME_OPENCLAW_AGENT_INSTANCE_ID_FILE_DEFAULT}"
}

edamame_openclaw_normalize_agent_instance_id() {
    python3 - "$1" <<'PY'
import re
import sys

value = sys.argv[1].strip().lower()
value = re.sub(r"\.local$", "", value)
value = re.sub(r"\s+\(\d+\)$", "", value)
value = value.replace("_", "-")
value = re.sub(r"[^a-z0-9-]+", "-", value)
value = re.sub(r"-{2,}", "-", value).strip("-")
print(value)
PY
}

edamame_openclaw_read_persisted_agent_instance_id() {
    local file
    local line
    file="$(edamame_openclaw_agent_instance_id_file)"
    if [ ! -f "$file" ]; then
        return 0
    fi
    if ! IFS= read -r line < "$file"; then
        return 0
    fi
    edamame_openclaw_normalize_agent_instance_id "$line"
}

edamame_openclaw_detect_host_label() {
    local raw="${EDAMAME_OPENCLAW_AGENT_HOSTNAME:-}"
    if [ -z "$raw" ] && [ "$(uname -s)" = "Darwin" ] && command -v scutil >/dev/null 2>&1; then
        raw="$(scutil --get ComputerName 2>/dev/null || true)"
    fi
    if [ -z "$raw" ] && command -v hostname >/dev/null 2>&1; then
        raw="$(hostname 2>/dev/null || true)"
    fi
    edamame_openclaw_normalize_agent_instance_id "$raw"
}

edamame_openclaw_is_legacy_agent_instance_id() {
    local candidate
    local host_label
    candidate="$(edamame_openclaw_normalize_agent_instance_id "${1:-}")"
    host_label="$(edamame_openclaw_normalize_agent_instance_id "${2:-}")"

    if [ -z "$candidate" ]; then
        return 1
    fi
    if [ "$candidate" = "openclaw-default" ] || [ "$candidate" = "main" ]; then
        return 0
    fi
    if [ -n "$host_label" ] && [ "$candidate" = "${host_label}-main" ]; then
        return 0
    fi
    return 1
}

edamame_openclaw_persist_agent_instance_id() {
    local candidate
    local file
    candidate="$(edamame_openclaw_normalize_agent_instance_id "${1:-}")"
    if [ -z "$candidate" ]; then
        return 1
    fi

    file="$(edamame_openclaw_agent_instance_id_file)"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$candidate" > "$file"
    chmod 600 "$file"
}

edamame_openclaw_resolve_agent_instance_id() {
    local explicit_candidate
    local override_candidate
    local persisted_candidate
    local host_label
    local resolved

    explicit_candidate="$(edamame_openclaw_normalize_agent_instance_id "${1:-}")"
    override_candidate="$(edamame_openclaw_normalize_agent_instance_id "${EDAMAME_OPENCLAW_AGENT_INSTANCE_ID:-}")"
    persisted_candidate="$(edamame_openclaw_read_persisted_agent_instance_id)"
    if [ -n "$persisted_candidate" ]; then
        printf '%s\n' "$persisted_candidate"
        return 0
    fi

    host_label="$(edamame_openclaw_detect_host_label)"

    if [ -n "$override_candidate" ]; then
        resolved="$override_candidate"
    elif [ -n "$explicit_candidate" ] && ! edamame_openclaw_is_legacy_agent_instance_id "$explicit_candidate" "$host_label"; then
        resolved="$explicit_candidate"
    elif [ -n "$host_label" ]; then
        resolved="$host_label"
    elif [ -n "$explicit_candidate" ]; then
        resolved="$explicit_candidate"
    else
        resolved="openclaw-default"
    fi

    edamame_openclaw_persist_agent_instance_id "$resolved" >/dev/null
    printf '%s\n' "$resolved"
}
