#!/usr/bin/env node
/**
 * Emits one JSON line for e2e_inject_intent.sh:
 * { agent_instance_id, session_keys[], raw_sessions: RawReasoningSessionPayload }
 *
 * Uses the same _buildRawPayload shape as the OpenClaw MCP plugin without calling
 * _resolveAgentInstanceId (which would write ~/.edamame_openclaw_agent_instance_id).
 *
 * When E2E_OPENCLAW_PLUGIN_ROOT is set, imports from the installed plugin at that
 * path (e.g. ~/.openclaw/extensions/edamame/index.ts). Otherwise falls back to
 * the repo-local copy at ../extensions/edamame/index.ts.
 */

import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { pathToFileURL } from "node:url"

const pluginRoot = process.env.E2E_OPENCLAW_PLUGIN_ROOT || ""
const indexPath = pluginRoot
    ? path.join(pluginRoot, "index.ts")
    : path.resolve(import.meta.dirname!, "../extensions/edamame/index.ts")
const repoIndexPath = path.resolve(import.meta.dirname!, "../extensions/edamame/index.ts")

const { _buildRawPayload, _normalizeAgentInstanceId } = await import(pathToFileURL(indexPath).href)
const { _callEdamameTool } = await import(pathToFileURL(repoIndexPath).href)

function readAgentInstanceIdForE2e(): string {
    const fromE2e = (process.env.E2E_OPENCLAW_AGENT_INSTANCE_ID || "").trim()
    if (fromE2e) return _normalizeAgentInstanceId(fromE2e)
    const fromEnv = (process.env.EDAMAME_OPENCLAW_AGENT_INSTANCE_ID || "").trim()
    if (fromEnv) return _normalizeAgentInstanceId(fromEnv)
    const filePath = path.join(os.homedir(), ".edamame_openclaw_agent_instance_id")
    try {
        const line = fs.readFileSync(filePath, "utf-8").split("\n")[0]?.trim()
        if (line) return _normalizeAgentInstanceId(line)
    } catch {
        /* missing file */
    }
    return _normalizeAgentInstanceId(os.hostname()) || "openclaw-default"
}

const ts = Date.now()
const agentInstanceId = readAgentInstanceIdForE2e()

/** Core rejects sessions where started_at > modified_at; avoid two `Date()` calls in wrong order. */
function openClawSessionTimes(staggerMs: number): { createdAt: string; updatedAt: string } {
    const startMs = ts + staggerMs
    const endMs = startMs + 120_000
    return {
        createdAt: new Date(startMs).toISOString(),
        updatedAt: new Date(endMs).toISOString(),
    }
}

const sessions = [
    {
        key: `oc_e2e_api_${ts}`,
        title: `OpenClaw E2E API ${ts}`,
        messages: [
            {
                role: "user",
                content: `EDAMAME oc_e2e_api ${ts}: call https://api.anthropic.com/v1/messages`,
            },
            {
                role: "assistant",
                content:
                    "[Tool call] http_request\n  command: curl -s https://api.anthropic.com/v1/models\n" +
                    "Received 200 OK from api.anthropic.com. Done for oc_e2e_api.",
            },
        ],
        ...openClawSessionTimes(0),
    },
    {
        key: `oc_e2e_shell_${ts}`,
        title: `OpenClaw E2E shell ${ts}`,
        messages: [
            {
                role: "user",
                content: `EDAMAME oc_e2e_shell ${ts}: npm registry lookup`,
            },
            {
                role: "assistant",
                content:
                    "[Tool call] run\n  command: curl -sL https://registry.npmjs.org/edamame | head -c 80\n" +
                    "Fetched package metadata from registry.npmjs.org. Done for oc_e2e_shell.",
            },
        ],
        ...openClawSessionTimes(1000),
    },
    {
        key: `oc_e2e_git_${ts}`,
        title: `OpenClaw E2E git ${ts}`,
        messages: [
            {
                role: "user",
                content: `EDAMAME oc_e2e_git ${ts}: clone git@github.com:edamametechnologies/threatmodels.git`,
            },
            {
                role: "assistant",
                content:
                    "[Tool call] run\n  command: git clone git@github.com:edamametechnologies/threatmodels.git /tmp/threatmodels\n" +
                    "Cloning into /tmp/threatmodels from github.com. Done for oc_e2e_git.",
            },
        ],
        ...openClawSessionTimes(2000),
    },
]

const raw_sessions = _buildRawPayload(sessions, "openclaw", agentInstanceId)
const session_keys = sessions.map((s) => s.key)

const pushViaMcp = (process.env.E2E_PUSH_VIA_MCP || "").trim() === "1"

if (pushViaMcp) {
    const rawJson = JSON.stringify(raw_sessions)
    const result = await _callEdamameTool(
        "upsert_behavioral_model_from_raw_sessions",
        { raw_sessions_json: rawJson },
        { timeoutMs: 120_000 },
    )
    const out = { agent_instance_id: agentInstanceId, session_keys, mcp_result: result }
    process.stdout.write(JSON.stringify(out) + "\n")
} else {
    process.stdout.write(
        JSON.stringify({
            agent_instance_id: agentInstanceId,
            session_keys,
            raw_sessions,
        }) + "\n",
    )
}
