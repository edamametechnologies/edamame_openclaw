#!/usr/bin/env node

import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch (_error) {
    return false;
  }
}

async function readFirstLine(filePath) {
  try {
    const data = await fs.readFile(filePath, "utf8");
    const line = data.split(/\r?\n/)[0]?.trim() ?? "";
    return line || null;
  } catch (_error) {
    return null;
  }
}

async function readPsk(config) {
  const envPsk = (process.env.EDAMAME_MCP_PSK || "").trim();
  if (envPsk) return envPsk;
  const pairingPsk = await readFirstLine(config.pskFile);
  if (pairingPsk) return pairingPsk;
  const simplePsk = await readFirstLine(config.simplePskFile);
  return simplePsk;
}

async function parseResponseJson(response) {
  const contentType = String(response.headers?.get?.("content-type") || "");
  if (contentType.includes("application/json")) {
    return response.json();
  }
  const raw = await response.text();
  const lines = raw.split(/\r?\n/);
  const dataPayloads = [];
  for (const line of lines) {
    if (line.startsWith("data: ")) {
      dataPayloads.push(line.slice("data: ".length));
    }
  }
  if (dataPayloads.length > 0) {
    return JSON.parse(dataPayloads.join(""));
  }
  return JSON.parse(raw.trim());
}

function classifyError(message) {
  const text = String(message || "").toLowerCase();
  if (text.includes("econnrefused") || text.includes("fetch failed") || text.includes("timeout")) {
    return { reason: "edamame_mcp_unreachable", message: String(message) };
  }
  if (text.includes("psk_missing") || text.includes("no psk")) {
    return { reason: "edamame_mcp_psk_missing", message: String(message) };
  }
  if (text.includes("http_401") || text.includes("unauthorized") || text.includes("auth")) {
    return { reason: "edamame_mcp_auth_failed", message: String(message) };
  }
  if (text.includes("http_404") || text.includes("session not found")) {
    return { reason: "edamame_mcp_session_error", message: String(message) };
  }
  return { reason: "edamame_mcp_unknown", message: String(message) };
}

function authRecoveryHint() {
  return "Run setup/pair.sh for app-mediated pairing, or set EDAMAME_MCP_PSK environment variable.";
}

async function callTool(toolName, args, config) {
  const psk = await readPsk(config);
  if (!psk) {
    throw new Error("edamame_mcp_psk_missing: No PSK found");
  }

  const fetchImpl = globalThis.fetch;
  if (typeof fetchImpl !== "function") {
    throw new Error("fetch_unavailable_node18_required");
  }

  const abortController = new AbortController();
  const timer = setTimeout(() => abortController.abort(), 30_000);

  try {
    const initId = 1;
    const initRes = await fetchImpl(config.endpoint, {
      method: "POST",
      headers: {
        Accept: "application/json, text/event-stream",
        "Content-Type": "application/json",
        Authorization: `Bearer ${psk}`,
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: initId,
        method: "initialize",
        params: {
          protocolVersion: "2025-11-25",
          capabilities: {},
          clientInfo: { name: "edamame_openclaw-healthcheck", version: "1.0.0" },
        },
      }),
      signal: abortController.signal,
    });

    if (initRes.status >= 400) {
      const body = (await initRes.text?.()) || "";
      throw new Error(`http_${initRes.status}: ${body.slice(0, 1000)}`);
    }

    const initJson = await parseResponseJson(initRes);
    if (initJson?.error) {
      throw new Error(`initialize_error: ${initJson.error.message}`);
    }

    const sessionId = String(initRes.headers?.get?.("mcp-session-id") || "").trim() || null;

    const baseHeaders = {
      Accept: "application/json, text/event-stream",
      "Content-Type": "application/json",
      Authorization: `Bearer ${psk}`,
    };
    if (sessionId) baseHeaders["Mcp-Session-Id"] = sessionId;

    await fetchImpl(config.endpoint, {
      method: "POST",
      headers: baseHeaders,
      body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }),
      signal: abortController.signal,
    });

    const toolId = 2;
    const toolRes = await fetchImpl(config.endpoint, {
      method: "POST",
      headers: baseHeaders,
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: toolId,
        method: "tools/call",
        params: { name: toolName, arguments: args },
      }),
      signal: abortController.signal,
    });

    if (toolRes.status >= 400) {
      const body = (await toolRes.text?.()) || "";
      throw new Error(`http_${toolRes.status}: ${body.slice(0, 1000)}`);
    }

    const toolJson = await parseResponseJson(toolRes);
    if (toolJson?.error) {
      throw new Error(`tools_call_error: ${toolJson.error.message}`);
    }

    const content = Array.isArray(toolJson?.result?.content) ? toolJson.result.content : [];
    const texts = content
      .filter((item) => item?.type === "text" && typeof item.text === "string")
      .map((item) => item.text);
    const text = texts.join("\n").trim();

    try {
      return JSON.parse(text);
    } catch (_error) {
      return text;
    }
  } catch (error) {
    const msg = String(error?.message || error);
    if (msg.includes("aborted")) throw new Error("timeout");
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

export function resolveConfig(options = {}) {
  const home = options.home || os.homedir();
  const openclawDir = path.join(home, ".openclaw");
  const stateDir = path.join(openclawDir, "edamame-openclaw", "state");
  const endpoint =
    options.endpoint ||
    process.env.EDAMAME_MCP_ENDPOINT ||
    "http://127.0.0.1:3000/mcp";

  return {
    home,
    openclawDir,
    endpoint,
    pskFile: path.join(stateDir, "edamame-mcp.psk"),
    simplePskFile: path.join(home, ".edamame_psk"),
  };
}

export async function runHealthcheck(config, options = {}) {
  const result = { ok: true, checks: [] };

  const addCheck = (name, ok, detail) => {
    result.checks.push({ name, ok, detail });
    if (!ok) result.ok = false;
  };

  addCheck(
    "config.openclawDir",
    await fileExists(config.openclawDir),
    config.openclawDir,
  );

  const hasPsk = await fileExists(config.pskFile);
  const hasSimplePsk = !hasPsk && (await fileExists(config.simplePskFile));
  addCheck("psk.file", hasPsk || hasSimplePsk, hasPsk ? config.pskFile : config.simplePskFile);

  if (!hasPsk && !hasSimplePsk) {
    result.ok = true;
    result.message = "awaiting_pairing";
    return result;
  }

  try {
    const [engineStatus, behavioralModel, verdict] = await Promise.all([
      callTool("get_divergence_engine_status", {}, config),
      callTool("get_behavioral_model", {}, config),
      callTool("get_divergence_verdict", {}, config),
    ]);

    addCheck("mcp.endpoint", true, config.endpoint);

    const hasBehavioralModel =
      !!behavioralModel &&
      !(
        Object.prototype.hasOwnProperty.call(behavioralModel, "model") &&
        behavioralModel.model === null
      );

    addCheck(
      "divergence.engine",
      engineStatus?.running === true,
      engineStatus,
    );
    addCheck("behavioral.model", hasBehavioralModel, behavioralModel);
  } catch (error) {
    const failure = classifyError(error?.message || error);
    addCheck("mcp.endpoint", false, {
      endpoint: config.endpoint,
      reason: failure.reason,
      message: failure.message,
      recovery:
        failure.reason === "edamame_mcp_auth_failed" || failure.reason === "edamame_mcp_psk_missing"
          ? authRecoveryHint()
          : undefined,
    });
    if (failure.reason === "edamame_mcp_auth_failed") {
      addCheck("mcp.authentication", false, {
        endpoint: config.endpoint,
        reason: failure.reason,
        message: failure.message,
        recovery: authRecoveryHint(),
      });
    }
  }

  if (options.strict) {
    result.ok = result.ok && result.checks.every((check) => check.ok);
  }

  return result;
}
