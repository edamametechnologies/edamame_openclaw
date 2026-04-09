import fs from "node:fs"
import path from "node:path"
import os from "node:os"
import { execSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import {
    type OpenClawSession,
    _buildRawPayload,
    _buildSessionPayload,
    _collapseRunSubSessions,
    _extractCommands,
    _extractPaths,
    _extractToolNames,
    _extractTraffic,
    _isSensitivePath,
    _toRfc3339,
} from "./session_payload.ts"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const PACKAGE_VERSION: string = (() => {
    try {
        const pkg = JSON.parse(fs.readFileSync(path.resolve(__dirname, "..", "..", "package.json"), "utf-8"))
        return pkg.version || "0.0.0"
    } catch {
        return "0.0.0"
    }
})()

type ToolTextContent = { type: "text"; text: string }
type ToolResult = { content: ToolTextContent[] }

function _asText(text: string): ToolResult {
    return { content: [{ type: "text", text }] }
}

type JsonRpcRequest = { jsonrpc: "2.0"; id?: number; method: string; params?: unknown }
type JsonRpcResponse = { jsonrpc: "2.0"; id: number; result?: any; error?: { code: number; message: string; data?: any } }

function _readFirstLine(p: string): string | null {
    try {
        const buf = fs.readFileSync(p, "utf-8")
        const line = buf.split(/\r?\n/)[0]?.trim() ?? ""
        return line === "" ? null : line
    } catch {
        return null
    }
}

function _getPsk(): string | null {
    const envPsk = (process.env.EDAMAME_MCP_PSK || "").trim()
    if (envPsk) return envPsk
    const home = process.env.HOME || ""
    if (!home) return null
    const pairing = _readFirstLine(path.join(home, ".openclaw", "edamame-openclaw", "state", "edamame-mcp.psk"))
    if (pairing) return pairing
    return _readFirstLine(path.join(home, ".edamame_psk"))
}

function _getAlertTo(): string {
    const env = (process.env.ALERT_TO || "").trim()
    if (env) return env
    const home = process.env.HOME || ""
    if (!home) return ""
    return _readFirstLine(path.join(home, ".openclaw_alert_to")) || ""
}

function _getAlertChannel(): string {
    const env = (process.env.ALERT_CHANNEL || "").trim()
    if (env) return env
    const home = process.env.HOME || ""
    if (!home) return "telegram"
    return _readFirstLine(path.join(home, ".openclaw_alert_channel")) || "telegram"
}

function _getEndpoint(): string {
    const env = (process.env.EDAMAME_MCP_ENDPOINT || "").trim()
    return env || "http://127.0.0.1:3000/mcp"
}

const _AGENT_INSTANCE_ID_FILE = ".edamame_openclaw_agent_instance_id"

function _getAgentInstanceIdFilePath(): string | null {
    const home = process.env.HOME || ""
    if (!home) return null
    return path.join(home, _AGENT_INSTANCE_ID_FILE)
}

function _normalizeAgentInstanceId(value: string): string {
    return value
        .trim()
        .toLowerCase()
        .replace(/\.local$/i, "")
        .replace(/\s+\(\d+\)$/i, "")
        .replace(/_/g, "-")
        .replace(/[^a-z0-9-]+/g, "-")
        .replace(/-{2,}/g, "-")
        .replace(/^-+|-+$/g, "")
}

function _readPersistedAgentInstanceId(): string | null {
    const filePath = _getAgentInstanceIdFilePath()
    if (!filePath) return null
    const value = _readFirstLine(filePath)
    if (!value) return null
    const normalized = _normalizeAgentInstanceId(value)
    return normalized || null
}

function _persistAgentInstanceId(value: string): string {
    const normalized = _normalizeAgentInstanceId(value)
    if (!normalized) return "openclaw-default"
    const filePath = _getAgentInstanceIdFilePath()
    if (filePath) {
        fs.mkdirSync(path.dirname(filePath), { recursive: true })
        fs.writeFileSync(filePath, `${normalized}\n`, { encoding: "utf-8", mode: 0o600 })
        try {
            fs.chmodSync(filePath, 0o600)
        } catch {
            // Ignore chmod failures on platforms that do not support it.
        }
    }
    return normalized
}

function _getMacosComputerName(): string {
    if (process.platform !== "darwin") return ""
    try {
        return execSync("scutil --get ComputerName", {
            encoding: "utf-8",
            stdio: ["ignore", "pipe", "ignore"],
            timeout: 5_000,
        }).trim()
    } catch {
        return ""
    }
}

function _canonicalHostAgentInstanceId(): string {
    const explicitHost = (process.env.EDAMAME_OPENCLAW_AGENT_HOSTNAME || "").trim()
    const rawHost = explicitHost || _getMacosComputerName() || os.hostname()
    return _normalizeAgentInstanceId(rawHost)
}

function _isLegacyAgentInstanceId(value: string, canonicalHostId: string): boolean {
    if (!value) return false
    if (value === "openclaw-default" || value === "main") return true
    return canonicalHostId !== "" && value === `${canonicalHostId}-main`
}

function _resolveAgentInstanceId(explicitId?: string): string {
    const envOverride = _normalizeAgentInstanceId(process.env.EDAMAME_OPENCLAW_AGENT_INSTANCE_ID || "")
    if (envOverride) return _persistAgentInstanceId(envOverride)

    const persisted = _readPersistedAgentInstanceId()
    if (persisted) return persisted

    const canonicalHostId = _canonicalHostAgentInstanceId()
    const explicit = _normalizeAgentInstanceId(explicitId || "")
    const candidate =
        explicit && !_isLegacyAgentInstanceId(explicit, canonicalHostId)
            ? explicit
            : canonicalHostId || explicit || "openclaw-default"

    return _persistAgentInstanceId(candidate)
}

function _getFetch(): any | null {
    const f = (globalThis as any).fetch
    return typeof f === "function" ? f : null
}

async function _readJsonOrSseResponse(
    res: any,
    options: { requestId: number; timeoutMs: number },
): Promise<JsonRpcResponse> {
    const { requestId, timeoutMs } = options
    const ct = String(res.headers?.get?.("content-type") || "")
    if (ct.includes("application/json")) {
        const obj = (await res.json()) as JsonRpcResponse
        return obj
    }

    if (!ct.includes("text/event-stream")) {
        const text = (await res.text?.()) || ""
        throw new Error(`unexpected_content_type: ${ct || "none"} body=${text.slice(0, 2000)}`)
    }

    const reader = res.body?.getReader?.()
    if (!reader) throw new Error("sse_no_body_reader")

    const decoder = new TextDecoder()
    let buffer = ""
    let dataLines: string[] = []

    const startMs = Date.now()
    while (Date.now() - startMs < timeoutMs) {
        const { value, done } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })

        while (true) {
            const nl = buffer.indexOf("\n")
            if (nl < 0) break
            let line = buffer.slice(0, nl)
            buffer = buffer.slice(nl + 1)
            if (line.endsWith("\r")) line = line.slice(0, -1)

            if (line === "") {
                if (dataLines.length === 0) continue
                const payload = dataLines.join("\n")
                dataLines = []
                if (payload.trim() === "") continue
                try {
                    const msg = JSON.parse(payload) as JsonRpcResponse
                    if ((msg as any)?.id === requestId) return msg
                } catch {
                    // Ignore non-JSON data events.
                }
                continue
            }

            if (line.startsWith("data:")) {
                let d = line.slice(5)
                if (d.startsWith(" ")) d = d.slice(1)
                dataLines.push(d)
            }
        }
    }

    throw new Error("sse_timeout_or_eof_without_response")
}

class McpHttpClient {
    private endpoint: string
    private psk: string
    private desiredProtocolVersion: string
    private protocolVersion: string | null
    private sessionId: string | null
    private nextId: number
    private initPromise: Promise<void> | null

    constructor(options: { endpoint: string; psk: string }) {
        this.endpoint = options.endpoint
        this.psk = options.psk
        this.desiredProtocolVersion = "2025-11-25"
        this.protocolVersion = null
        this.sessionId = null
        this.nextId = 1
        this.initPromise = null
    }

    sameConfig(options: { endpoint: string; psk: string }): boolean {
        return this.endpoint === options.endpoint && this.psk === options.psk
    }

    private _headers(): Record<string, string> {
        const h: Record<string, string> = {
            Accept: "application/json, text/event-stream",
            "Content-Type": "application/json",
            Authorization: `Bearer ${this.psk}`,
        }
        if (this.sessionId) h["Mcp-Session-Id"] = this.sessionId
        return h
    }

    private async _post(
        msg: JsonRpcRequest,
        options: { timeoutMs: number; expectResponse: boolean },
    ): Promise<{ res: any; responseJson?: JsonRpcResponse }> {
        const fetchAny = _getFetch()
        if (!fetchAny) throw new Error("fetch_unavailable_node18_required")

        const ac = new AbortController()
        const t = setTimeout(() => ac.abort(), options.timeoutMs)
        try {
            const res = await fetchAny(this.endpoint, {
                method: "POST",
                headers: this._headers(),
                body: JSON.stringify(msg),
                signal: ac.signal,
            })

            if (res.status >= 400) {
                const body = (await res.text?.()) || ""
                throw new Error(`http_${res.status}: ${body.slice(0, 2000)}`)
            }

            if (!options.expectResponse) {
                // For notifications/responses, server returns 202 Accepted with no body.
                return { res }
            }

            const responseJson = await _readJsonOrSseResponse(res, {
                requestId: msg.id as number,
                timeoutMs: options.timeoutMs,
            })
            return { res, responseJson }
        } catch (e: any) {
            const msg = String(e?.message || e)
            if (msg.includes("aborted")) throw new Error("timeout")
            throw e
        } finally {
            clearTimeout(t)
        }
    }

    private async _initializeOnce(timeoutMs: number): Promise<void> {
        const initId = this.nextId++
        const initReq: JsonRpcRequest = {
            jsonrpc: "2.0",
            id: initId,
            method: "initialize",
            params: {
                protocolVersion: this.desiredProtocolVersion,
                capabilities: {},
                clientInfo: {
                    name: "edamame_openclaw-edamame",
                    version: PACKAGE_VERSION,
                },
            },
        }

        // Initialize must be the first interaction. Do NOT send MCP-Protocol-Version header yet;
        // some servers will reject unsupported header values before version negotiation completes.
        const prevProtocol = this.protocolVersion
        this.protocolVersion = null

        const { res, responseJson } = await this._post(initReq, { timeoutMs, expectResponse: true })
        this.protocolVersion = prevProtocol

        if (!responseJson) throw new Error("initialize_missing_response")
        if (responseJson.error) throw new Error(`initialize_error: ${responseJson.error.message}`)

        const negotiated = String(responseJson.result?.protocolVersion || "").trim()
        this.protocolVersion = negotiated || this.desiredProtocolVersion

        const sid = String(res.headers?.get?.("mcp-session-id") || "").trim()
        this.sessionId = sid || null

        // Complete lifecycle.
        await this._post(
            { jsonrpc: "2.0", method: "notifications/initialized" },
            { timeoutMs: Math.min(10_000, timeoutMs), expectResponse: false },
        )
    }

    async ensureInitialized(timeoutMs: number): Promise<void> {
        if (this.initPromise) return await this.initPromise

        this.initPromise = (async () => {
            // If we already have a session ID + negotiated protocol version, assume initialized.
            // Tool calls will handle HTTP 404 and force re-init.
            if (this.protocolVersion) return
            await this._initializeOnce(timeoutMs)
        })()

        try {
            await this.initPromise
        } finally {
            this.initPromise = null
        }
    }

    private _responseToToolText(responseJson: JsonRpcResponse): string {
        if (responseJson.error) throw new Error(`tools_call_error: ${responseJson.error.message}`)
        const result = responseJson.result || {}
        const content = Array.isArray(result.content) ? result.content : []
        const texts: string[] = []
        for (const item of content) {
            if (item && item.type === "text" && typeof item.text === "string") {
                texts.push(item.text)
            }
        }
        if (texts.length > 0) return texts.join("\n").trim()
        if (result.structuredContent !== undefined) return JSON.stringify(result.structuredContent)
        return JSON.stringify(result)
    }

    private _looksLikeSessionExpiry(text: string): boolean {
        const t = text.toLowerCase()
        return (
            t.includes("session not found") ||
            t.includes("mcp-session-id") ||
            t.includes("http_401") ||
            (t.includes("unauthorized") && t.includes("session"))
        )
    }

    private async _callToolOnce(req: JsonRpcRequest, timeoutMs: number): Promise<string> {
        const { responseJson } = await this._post(req, { timeoutMs, expectResponse: true })
        if (!responseJson) throw new Error("tools_call_missing_response")
        return this._responseToToolText(responseJson)
    }

    async callTool(toolName: string, args: Record<string, unknown>, timeoutMs: number): Promise<string> {
        await this.ensureInitialized(Math.min(30_000, timeoutMs))

        const id = this.nextId++
        const req: JsonRpcRequest = {
            jsonrpc: "2.0",
            id,
            method: "tools/call",
            params: { name: toolName, arguments: args },
        }

        try {
            const text = await this._callToolOnce(req, timeoutMs)
            if (this._looksLikeSessionExpiry(text)) {
                this.protocolVersion = null
                this.sessionId = null
                await this.ensureInitialized(Math.min(30_000, timeoutMs))
                return await this._callToolOnce(req, timeoutMs)
            }
            return text
        } catch (e: any) {
            // If the server dropped our session, retry once with a fresh init.
            const msg = String(e?.message || e)
            const msgLower = msg.toLowerCase()
            if (
                msg.startsWith("http_404") ||
                msg.startsWith("http_401") ||
                msgLower.includes("session") ||
                msgLower.includes("mcp-session-id")
            ) {
                this.protocolVersion = null
                this.sessionId = null
                await this.ensureInitialized(Math.min(30_000, timeoutMs))
                return await this._callToolOnce(req, timeoutMs)
            }
            throw e
        }
    }
}

let _client: McpHttpClient | null = null

function _getClient(): McpHttpClient | null {
    const endpoint = _getEndpoint()
    const psk = _getPsk()
    if (!psk) return null
    const cfg = { endpoint, psk }
    if (_client && _client.sameConfig(cfg)) return _client
    _client = new McpHttpClient(cfg)
    return _client
}

async function _callEdamameTool(
    toolName: string,
    kvArgs: Record<string, unknown>,
    options?: { timeoutMs?: number },
): Promise<string> {
    const timeoutMs = options?.timeoutMs ?? 60_000
    const client = _getClient()
    if (!client) {
        throw new Error("missing EDAMAME MCP credential (~/.edamame_psk or EDAMAME_MCP_PSK). Run setup/pair.sh for app-mediated pairing or setup/provision.sh for VM/daemon.")
    }

    return await client.callTool(toolName, kvArgs, timeoutMs)
}

async function _callEdamameToolSafe(
    toolName: string,
    kvArgs: Record<string, unknown>,
    options?: { timeoutMs?: number },
): Promise<{ text: string; isError: boolean }> {
    try {
        const text = await _callEdamameTool(toolName, kvArgs, options)
        return { text, isError: false }
    } catch (e: any) {
        return { text: String(e?.message || e), isError: true }
    }
}

function _asError(message: string): ToolResult {
    return { content: [{ type: "text", text: `ERROR: ${message}` }] }
}

type GetSessionsArgs = {
    active_only?: boolean
    limit?: number
    since?: number | string
}
const DEFAULT_GET_SESSIONS_LIMIT = 200

function _toEpochMs(value: unknown): number | null {
    if (typeof value === "number" && Number.isFinite(value)) {
        if (value > 1e12) return Math.floor(value) // already milliseconds
        if (value > 1e9) return Math.floor(value * 1000) // seconds
        return null
    }

    if (typeof value === "string") {
        const trimmed = value.trim()
        if (!trimmed) return null
        if (/^\d+(\.\d+)?$/.test(trimmed)) return _toEpochMs(Number(trimmed))
        const parsed = Date.parse(trimmed)
        return Number.isNaN(parsed) ? null : parsed
    }

    return null
}

function _sessionActivityMs(session: any): number | null {
    return (
        _toEpochMs(session?.stats?.last_activity) ??
        _toEpochMs(session?.stats?.end_time) ??
        _toEpochMs(session?.stats?.start_time) ??
        _toEpochMs(session?.last_activity) ??
        _toEpochMs(session?.updated_at) ??
        _toEpochMs(session?.updatedAt)
    )
}

function _filterGetSessionsPayload(rawText: string, args: GetSessionsArgs): string {
    let parsed: any
    try {
        parsed = JSON.parse(rawText)
    } catch {
        return rawText
    }

    let rows: any[] | null = null
    let rehydrate = (filteredRows: any[]) => JSON.stringify(filteredRows, null, 2)

    if (Array.isArray(parsed)) {
        rows = parsed
    } else if (parsed && typeof parsed === "object" && Array.isArray(parsed.sessions)) {
        rows = parsed.sessions
        rehydrate = (filteredRows: any[]) => {
            const next = { ...parsed, sessions: filteredRows }
            if (typeof next.count === "number") next.count = filteredRows.length
            return JSON.stringify(next, null, 2)
        }
    } else {
        return rawText
    }

    const activeOnly = args.active_only ?? true
    const sinceMs = _toEpochMs(args.since)
    const limit =
        typeof args.limit === "number" && Number.isFinite(args.limit) && args.limit > 0
            ? Math.floor(args.limit)
            : DEFAULT_GET_SESSIONS_LIMIT

    let filtered = rows
    if (activeOnly) {
        filtered = filtered.filter((row: any) => row?.status?.active === true)
    }

    if (sinceMs !== null) {
        filtered = filtered.filter((row: any) => {
            const activityMs = _sessionActivityMs(row)
            return activityMs !== null && activityMs >= sinceMs
        })
    }

    if (filtered.length > limit) {
        const ranked = filtered.map((row: any, index: number) => ({
            row,
            index,
            activityMs: _sessionActivityMs(row) ?? Number.NEGATIVE_INFINITY,
        }))
        ranked.sort((a, b) => {
            if (a.activityMs !== b.activityMs) return b.activityMs - a.activityMs
            return a.index - b.index
        })
        filtered = ranked.slice(0, limit).map((entry) => entry.row)
    }

    filtered = filtered.map(_trimSession)
    return rehydrate(filtered)
}

function _trimSession(s: any): any {
    if (!s || typeof s !== "object") return s

    const stats = s.stats
    const trimmedStats = stats
        ? {
              start_time: stats.start_time,
              last_activity: stats.last_activity,
              inbound_bytes: stats.inbound_bytes,
              outbound_bytes: stats.outbound_bytes,
              history: stats.history,
              conn_state: stats.conn_state,
          }
        : undefined

    const l7 = s.l7
    const trimmedL7 = l7
        ? {
              pid: l7.pid,
              process_name: l7.process_name,
              process_path: l7.process_path,
              cmd: l7.cmd,
              cwd: l7.cwd,
              open_files: l7.open_files,
              parent_pid: l7.parent_pid,
              parent_process_name: l7.parent_process_name,
              parent_process_path: l7.parent_process_path,
              parent_cmd: l7.parent_cmd,
              parent_script_path: l7.parent_script_path,
              grandparent_pid: l7.grandparent_pid,
              grandparent_process_name: l7.grandparent_process_name,
              grandparent_process_path: l7.grandparent_process_path,
              grandparent_cmd: l7.grandparent_cmd,
              grandparent_script_path: l7.grandparent_script_path,
              spawned_from_tmp: l7.spawned_from_tmp,
          }
        : undefined

    return {
        session: s.session,
        status: s.status ? { active: s.status.active } : undefined,
        stats: trimmedStats,
        is_self_src: s.is_self_src,
        is_self_dst: s.is_self_dst,
        src_domain: s.src_domain,
        dst_domain: s.dst_domain,
        dst_service: s.dst_service,
        l7: trimmedL7,
        dst_asn: s.dst_asn,
        is_whitelisted: s.is_whitelisted,
        criticality: s.criticality,
        uid: s.uid,
    }
}

function _trimSessionList(rawText: string): string {
    let parsed: any
    try {
        parsed = JSON.parse(rawText)
    } catch {
        return rawText
    }
    if (Array.isArray(parsed)) {
        return JSON.stringify(parsed.map(_trimSession), null, 2)
    }
    if (parsed && typeof parsed === "object" && Array.isArray(parsed.sessions)) {
        const out = { ...parsed, sessions: parsed.sessions.map(_trimSession) }
        if (typeof out.count === "number") out.count = out.sessions.length
        return JSON.stringify(out, null, 2)
    }
    return rawText
}

function _trimThreat(t: any): any {
    if (!t || typeof t !== "object") return t
    const { description, implementation, remediation, rollback, ...rest } = t
    return rest
}

function _trimScorePayload(rawText: string): string {
    let parsed: any
    try {
        parsed = JSON.parse(rawText)
    } catch {
        return rawText
    }
    if (!parsed || typeof parsed !== "object") return rawText

    const trimList = (arr: unknown) =>
        Array.isArray(arr) ? arr.map(_trimThreat) : arr

    const out: any = {
        network: parsed.network,
        system_integrity: parsed.system_integrity,
        system_services: parsed.system_services,
        applications: parsed.applications,
        credentials: parsed.credentials,
        overall: parsed.overall,
        stars: parsed.stars,
        active: trimList(parsed.active ?? parsed.threats),
        newly_active: trimList(parsed.newly_active),
        newly_inactive: trimList(parsed.newly_inactive),
        compliance: parsed.compliance,
        compute_in_progress: parsed.compute_in_progress,
        last_compute: parsed.last_compute,
    }
    return JSON.stringify(out, null, 2)
}

// Deterministic session-to-raw-payload extraction lives in `session_payload.ts`
// so the OpenClaw plugin entrypoint can stay focused on transport and tool
// registration.

export {
    _filterGetSessionsPayload,
    _trimScorePayload,
    _trimSession,
    _trimThreat,
    _buildSessionPayload,
    _buildRawPayload,
    _collapseRunSubSessions,
    _extractTraffic,
    _extractToolNames,
    _extractCommands,
    _extractPaths,
    _isSensitivePath,
    _toEpochMs,
    _sessionActivityMs,
    _toRfc3339,
    _normalizeAgentInstanceId,
    _isLegacyAgentInstanceId,
    _resolveAgentInstanceId,
    _callEdamameTool,
    _callEdamameToolSafe,
    _getPsk,
}
export type { GetSessionsArgs, OpenClawSession }

export default function register(api: any) {
    // Read-only surfaces used by the two-plane monitor + benchmark harness.
    api.registerTool({
        name: "advisor_get_todos",
        description: "EDAMAME MCP: list all security findings (todos). Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const { text, isError } = await _callEdamameToolSafe("advisor_get_todos", {})
            return isError ? _asError(text) : _asText(text)
        },
    })

    // Network observation tools — raw system-plane telemetry for two-plane correlation.
    api.registerTool({
        name: "get_sessions",
        description:
            "EDAMAME MCP: get observed network sessions with optional wrapper-side filtering. Defaults to active sessions only plus a 200-session cap to keep context small. Read-only.",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                active_only: { type: "boolean" },
                limit: { type: "integer", minimum: 1, maximum: 10000 },
                since: {
                    anyOf: [{ type: "integer", minimum: 0 }, { type: "string", minLength: 1 }],
                },
            },
        },
        async execute(_id: string, params: GetSessionsArgs = {}) {
            const upstreamArgs: Record<string, unknown> = {}
            if (typeof params.active_only === "boolean") {
                upstreamArgs.active_only = params.active_only
            }
            if (
                typeof params.limit === "number" &&
                Number.isFinite(params.limit) &&
                params.limit > 0
            ) {
                upstreamArgs.limit = Math.floor(params.limit)
            }

            const { text, isError } = await _callEdamameToolSafe("get_sessions", upstreamArgs)
            if (isError) return _asError(text)
            return _asText(_filterGetSessionsPayload(text, params))
        },
    })

    api.registerTool({
        name: "get_anomalous_sessions",
        description:
            "EDAMAME MCP: get sessions flagged as statistically anomalous. High-value signal for detecting prompt injection or data exfiltration. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const { text, isError } = await _callEdamameToolSafe("get_anomalous_sessions", {})
            if (isError) return _asError(text)
            return _asText(_trimSessionList(text))
        },
    })

    api.registerTool({
        name: "get_blacklisted_sessions",
        description:
            "EDAMAME MCP: get sessions to known-malicious destinations. Highest-confidence signal — any match indicates compromise. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const { text, isError } = await _callEdamameToolSafe("get_blacklisted_sessions", {})
            if (isError) return _asError(text)
            return _asText(_trimSessionList(text))
        },
    })

    api.registerTool({
        name: "get_exceptions",
        description:
            "EDAMAME MCP: get sessions violating whitelist/policy rules. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const { text, isError } = await _callEdamameToolSafe("get_exceptions", {})
            if (isError) return _asError(text)
            return _asText(_trimSessionList(text))
        },
    })

    // Multi-dimensional observation: LAN, Identity, and Posture Score.
    api.registerTool({
        name: "get_lan_devices",
        description:
            "EDAMAME MCP: get all discovered LAN devices with IPs, open ports, CVEs, OS fingerprints. Enables lateral-movement detection. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const { text, isError } = await _callEdamameToolSafe("get_lan_devices", {})
            return isError ? _asError(text) : _asText(text)
        },
    })

    api.registerTool({
        name: "get_lan_host_device",
        description:
            "EDAMAME MCP: get this host's own device info as seen by the LAN scanner — IPs, MAC, open ports, OS fingerprint. Enables vulnerability detection: detect internet-exposed services (e.g. STRIKE-class exposed gateways) before an attacker connects. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const { text, isError } = await _callEdamameToolSafe("get_lan_host_device", {})
            return isError ? _asError(text) : _asText(text)
        },
    })

    api.registerTool({
        name: "get_breaches",
        description:
            "EDAMAME MCP: get HIBP breach data for all monitored identities. Enables credential-stuffing detection. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const { text, isError } = await _callEdamameToolSafe("get_breaches", {})
            return isError ? _asError(text) : _asText(text)
        },
    })

    // Identity management — dynamically register/remove emails for HIBP breach monitoring.
    api.registerTool({
        name: "add_pwned_email",
        description:
            "EDAMAME MCP: add an email to HIBP breach monitoring. The email will be continuously watched for new breaches. (SIDE EFFECTS).",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                email: { type: "string", minLength: 1 },
            },
            required: ["email"],
        },
        async execute(_id: string, params: { email: string }) {
            const { text, isError } = await _callEdamameToolSafe("add_pwned_email", { email: params.email })
            return isError ? _asError(text) : _asText(text)
        },
    })

    api.registerTool({
        name: "remove_pwned_email",
        description:
            "EDAMAME MCP: remove an email from HIBP breach monitoring. (SIDE EFFECTS).",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                email: { type: "string", minLength: 1 },
            },
            required: ["email"],
        },
        async execute(_id: string, params: { email: string }) {
            const { text, isError } = await _callEdamameToolSafe("remove_pwned_email", { email: params.email })
            return isError ? _asError(text) : _asText(text)
        },
    })

    api.registerTool({
        name: "get_pwned_emails",
        description:
            "EDAMAME MCP: list all emails currently monitored for HIBP breaches with per-email summary and breach counts. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const { text, isError } = await _callEdamameToolSafe("get_pwned_emails", {})
            return isError ? _asError(text) : _asText(text)
        },
    })

    // LAN scan configuration — enable/disable continuous network discovery.
    api.registerTool({
        name: "set_lan_auto_scan",
        description:
            "EDAMAME MCP: enable or disable continuous LAN auto-scanning for devices, open ports, and CVEs. (SIDE EFFECTS).",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                enabled: { type: "boolean" },
            },
            required: ["enabled"],
        },
        async execute(_id: string, params: { enabled: boolean }) {
            const { text, isError } = await _callEdamameToolSafe("set_lan_auto_scan", { enabled: params.enabled })
            return isError ? _asError(text) : _asText(text)
        },
    })

    api.registerTool({
        name: "get_score",
        description:
            "EDAMAME MCP: get security posture score with sub-scores, active threat names/severity, and compliance status. " +
            "Heavy fields (description, implementation, remediation, rollback) are stripped to keep context small. Read-only.",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                full: {
                    type: "boolean",
                    description: "Return full threat details including descriptions and remediation (default: false, trimmed).",
                },
            },
        },
        async execute(_id: string, params: { full?: boolean }) {
            const { text, isError } = await _callEdamameToolSafe("get_score", { full: params.full === true })
            if (isError) return _asError(text)
            // When full=false (default), heavy threat fields (description,
            // implementation, remediation, rollback) are stripped from the
            // response by _trimScorePayload to keep context small. Pass
            // full=true (via the "full" parameter) to get unmodified output.
            if (params.full) return _asText(text)
            return _asText(_trimScorePayload(text))
        },
    })

    // Behavioral model bridge for the internal divergence engine.
    api.registerTool({
        name: "upsert_behavioral_model",
        description:
            "EDAMAME MCP: upsert the behavioral model consumed by the internal divergence engine. (SIDE EFFECTS).",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                window_json: {
                    type: "string",
                    minLength: 2,
                    description:
                        "Behavioral model payload serialized as JSON string (preferred wire format).",
                },
                window: {
                    type: "object",
                    description:
                        "Behavioral model payload object; will be serialized to window_json.",
                },
            },
        },
        async execute(
            _id: string,
            params: { window_json?: string; window?: Record<string, unknown> },
        ) {
            const payload =
                typeof params.window_json === "string" && params.window_json.trim() !== ""
                    ? params.window_json
                    : params.window
                      ? JSON.stringify(params.window)
                      : ""
            if (!payload) {
                return _asError("missing window_json (or window object) payload")
            }
            const { text, isError } = await _callEdamameToolSafe("upsert_behavioral_model", {
                window_json: payload,
            })
            return isError ? _asError(text) : _asText(text)
        },
    })

    api.registerTool({
        name: "get_behavioral_model",
        description:
            "EDAMAME MCP: fetch the current behavioral model used by the divergence engine. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const { text, isError } = await _callEdamameToolSafe("get_behavioral_model", {})
            return isError ? _asError(text) : _asText(text)
        },
    })

    api.registerTool({
        name: "advisor_get_action_history",
        description: "EDAMAME MCP: fetch action audit trail. Read-only.",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                limit: { type: "integer", minimum: 1, maximum: 500 },
            },
        },
        async execute(_id: string, params: { limit?: number }) {
            const { text, isError } = await _callEdamameToolSafe("advisor_get_action_history", { limit: params.limit ?? 50 })
            return isError ? _asError(text) : _asText(text)
        },
    })

    api.registerTool({
        name: "agentic_process_todos",
        description:
            "EDAMAME MCP: AI triage for todos (no execution). Returns categorized results. Read-only in analyze mode.",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                confirmation_level: { type: "string", enum: ["auto", "manual"] },
            },
        },
        async execute(_id: string, params: { confirmation_level?: "auto" | "manual" }) {
            const { text, isError } = await _callEdamameToolSafe("agentic_process_todos", {
                confirmation_level: params.confirmation_level ?? "manual",
            })
            return isError ? _asError(text) : _asText(text)
        },
    })

    api.registerTool({
        name: "agentic_get_workflow_status",
        description: "EDAMAME MCP: get current agentic workflow status. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const { text, isError } = await _callEdamameToolSafe("agentic_get_workflow_status", {})
            return isError ? _asError(text) : _asText(text)
        },
    })

    // Potentially mutating tools (kept for completeness; skill instructions forbid these in benchmark mode).
    api.registerTool({
        name: "agentic_execute_action",
        description: "EDAMAME MCP: execute a specific pending action (SIDE EFFECTS).",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                action_id: { type: "string", minLength: 1 },
            },
            required: ["action_id"],
        },
        async execute(_id: string, params: { action_id: string }) {
            const { text, isError } = await _callEdamameToolSafe("agentic_execute_action", { action_id: params.action_id })
            return isError ? _asError(text) : _asText(text)
        },
    })

    api.registerTool({
        name: "advisor_undo_action",
        description: "EDAMAME MCP: undo a specific action (SIDE EFFECTS).",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                action_id: { type: "string", minLength: 1 },
            },
            required: ["action_id"],
        },
        async execute(_id: string, params: { action_id: string }) {
            const { text, isError } = await _callEdamameToolSafe("advisor_undo_action", { action_id: params.action_id })
            return isError ? _asError(text) : _asText(text)
        },
    })

    api.registerTool({
        name: "advisor_undo_all_actions",
        description: "EDAMAME MCP: undo all actions from current session (SIDE EFFECTS).",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const { text, isError } = await _callEdamameToolSafe("advisor_undo_all_actions", {})
            return isError ? _asError(text) : _asText(text)
        },
    })

    // Raw session ingest — forwards transcript data to EDAMAME's internal LLM
    // for behavioral model generation, bypassing the OpenClaw agent LLM entirely.
    api.registerTool({
        name: "upsert_behavioral_model_from_raw_sessions",
        description:
            "EDAMAME MCP: forward raw reasoning-session transcripts to EDAMAME, " +
            "which builds a behavioral model slice using its internal LLM. " +
            "This eliminates the need for the OpenClaw agent LLM to generate the model. (SIDE EFFECTS).",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                raw_sessions_json: {
                    type: "string",
                    minLength: 2,
                    description:
                        "JSON-encoded RawReasoningSessionPayload with window_start, window_end, " +
                        "agent_type, agent_instance_id, source_kind, and sessions array.",
                },
            },
            required: ["raw_sessions_json"],
        },
        async execute(_id: string, params: { raw_sessions_json: string }) {
            const { text, isError } = await _callEdamameToolSafe("upsert_behavioral_model_from_raw_sessions", {
                raw_sessions_json: params.raw_sessions_json,
            }, { timeoutMs: 240_000 }) // 240s: large payloads need extended time for LLM inference
            return isError ? _asError(text) : _asText(text)
        },
    })

    // Compiled extrapolation cycle — deterministic, zero OpenClaw LLM tokens.
    // Reads OpenClaw session history via gateway API, deterministically extracts
    // structured data (domains, ports, commands, file paths), builds a
    // RawReasoningSessionPayload, and forwards it to EDAMAME's internal LLM via
    // upsert_behavioral_model_from_raw_sessions. Returns a summary of the cycle.
    api.registerTool({
        name: "extrapolator_run_cycle",
        description:
            "Run a full extrapolation cycle: read recent OpenClaw session transcripts, " +
            "deterministically extract behavioral signals, and forward to EDAMAME's " +
            "internal LLM via upsert_behavioral_model_from_raw_sessions. " +
            "Returns cycle summary. Zero OpenClaw agent LLM tokens consumed. (SIDE EFFECTS).",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                active_minutes: {
                    type: "integer",
                    minimum: 1,
                    maximum: 60,
                    description: "Sliding window in minutes for recent sessions (default: 15).",
                },
                agent_instance_id: {
                    type: "string",
                    description:
                        "Stable identifier for this OpenClaw deployment (default: persisted deployment identity).",
                },
            },
        },
        async execute(
            _id: string,
            params: { active_minutes?: number; agent_instance_id?: string },
        ) {
            const activeMinutes = params.active_minutes ?? 15
            const agentType = "openclaw"
            const agentInstanceId = _resolveAgentInstanceId(params.agent_instance_id)

            // Step 1: Enumerate recent sessions via OpenClaw CLI
            const npmGlobal = path.join(process.env.HOME || "", ".npm-global", "bin")
            const localNode = path.join(process.env.HOME || "", ".local", "node-v22", "bin")
            const envPath = `${localNode}:${npmGlobal}:${process.env.PATH || ""}`

            let sessions: OpenClawSession[] = []
            try {
                const listOut = execSync(
                    `openclaw sessions --json --active ${activeMinutes}`,
                    {
                        env: { ...process.env, PATH: envPath },
                        timeout: 30_000,
                        encoding: "utf-8",
                        stdio: ["pipe", "pipe", "pipe"],
                    },
                )
                const parsed = JSON.parse(listOut)
                const rawSessions: any[] = Array.isArray(parsed)
                    ? parsed
                    : Array.isArray(parsed?.sessions)
                        ? parsed.sessions
                        : []
                const sessionsDir = parsed?.path
                    ? path.dirname(parsed.path)
                    : ""

                for (const s of rawSessions) {
                    const key = s.key || s.sessionKey || s.id
                    if (!key) continue

                    let messages: Array<{ role: string; content: string }> = []
                    const sid = s.sessionId || s.session_id
                    if (sid && sessionsDir) {
                        const jsonlPath = path.join(sessionsDir, `${sid}.jsonl`)
                        try {
                            const raw = fs.readFileSync(jsonlPath, "utf-8")
                            const lines = raw.split("\n").filter((l: string) => l.trim())
                            const MAX_LINES = 100
                            const tail = lines.slice(-MAX_LINES)
                            for (const line of tail) {
                                try {
                                    const entry = JSON.parse(line)
                                    const role = entry.role || entry.type || ""
                                    const content =
                                        entry.content ||
                                        entry.text ||
                                        entry.message ||
                                        ""
                                    if (role && content) {
                                        messages.push({ role, content: String(content).slice(0, 4000) })
                                    }
                                } catch { /* skip malformed lines */ }
                            }
                        } catch { /* session file missing or unreadable */ }
                    }

                    const updated = s.updatedAt || s.updated_at
                    sessions.push({
                        key,
                        title: s.title || s.name,
                        messages,
                        updatedAt: updated,
                        createdAt: s.createdAt || s.created_at || updated,
                    })
                }

                // Collapse :run: sub-sessions into their parent cron session.
                // openclaw enumerates both the parent cron window and each
                // individual run as separate sessions. Without collapsing, the
                // LLM creates one empty prediction per entry.
                sessions = _collapseRunSubSessions(sessions)
            } catch (e: any) {
                return _asError(
                    `Failed to enumerate OpenClaw sessions: ${String(e?.stderr || e?.message || e).slice(0, 500)}`,
                )
            }

            if (sessions.length === 0) {
                // Push a heartbeat window so EDAMAME knows the extrapolator
                // is alive and no reasoning activity is happening. Without this,
                // the divergence engine may emit STALE or NO_MODEL verdicts.
                const now = new Date()
                const heartbeatWindow = {
                    window_start: new Date(now.getTime() - activeMinutes * 60_000).toISOString(),
                    window_end: now.toISOString(),
                    agent_type: agentType,
                    agent_instance_id: agentInstanceId,
                    predictions: [
                        {
                            agent_type: agentType,
                            agent_instance_id: agentInstanceId,
                            session_key: `agent:${agentInstanceId}:cron:heartbeat`,
                            action: "Periodic extrapolator cron tick with no new reasoning activity to model.",
                            tools_called: [],
                            scope_process_paths: [],
                            scope_parent_paths: [],
                            scope_grandparent_paths: [],
                            scope_any_lineage_paths: [
                                "*/openclaw-gateway",
                                "*/bin/openclaw",
                                "*\\openclaw-gateway",
                                "*\\bin\\openclaw",
                                "*/lib/node_modules/openclaw",
                                "*/.npm-global/",
                            ],
                            expected_traffic: [
                                "openclaw.com:443",
                                "githubusercontent.com:443",
                                "github.com:443",
                            ],
                            expected_sensitive_files: [],
                            expected_lan_devices: [],
                            expected_local_open_ports: [],
                            expected_process_paths: [],
                            expected_parent_paths: [],
                            expected_grandparent_paths: [],
                            expected_open_files: [],
                            expected_l7_protocols: ["https"],
                            expected_system_config: ["gateway.cron.cortex_extrapolator.enabled=true"],
                            not_expected_traffic: [],
                            not_expected_sensitive_files: [],
                            not_expected_lan_devices: [],
                            not_expected_local_open_ports: [],
                            not_expected_process_paths: [],
                            not_expected_parent_paths: [],
                            not_expected_grandparent_paths: [],
                            not_expected_open_files: [],
                            not_expected_l7_protocols: [],
                            not_expected_system_config: [],
                        },
                    ],
                    contributors: [],
                    version: PACKAGE_VERSION,
                    hash: "",
                    ingested_at: now.toISOString(),
                }

                let heartbeatSummary: string
                try {
                    heartbeatSummary = await _callEdamameTool(
                        "upsert_behavioral_model",
                        { window_json: JSON.stringify(heartbeatWindow) },
                        { timeoutMs: 30_000 },
                    )
                } catch (e: any) {
                    return _asError(`Heartbeat upsert failed: ${String(e?.message || e).slice(0, 500)}`)
                }

                return _asText(
                    JSON.stringify({
                        success: true,
                        mode: "compiled",
                        sessions_processed: 0,
                        reason: "heartbeat",
                        agent_type: agentType,
                        agent_instance_id: agentInstanceId,
                        upsert_summary: String(heartbeatSummary).slice(0, 500),
                    }),
                )
            }

            // Step 2: Build raw payload deterministically
            const rawPayload = _buildRawPayload(sessions, agentType, agentInstanceId)

            // Step 3: Forward to EDAMAME's internal LLM
            const rawJson = JSON.stringify(rawPayload)
            let upsertResult: string
            try {
                upsertResult = await _callEdamameTool(
                    "upsert_behavioral_model_from_raw_sessions",
                    { raw_sessions_json: rawJson },
                    { timeoutMs: 240_000 }, // 240s: large payloads need extended time for LLM inference
                )
            } catch (e: any) {
                return _asText(
                    JSON.stringify({
                        success: false,
                        mode: "compiled",
                        sessions_processed: sessions.length,
                        error: String(e?.message || e),
                    }),
                )
            }

            // Step 4: Verify read-back
            let model: string
            let readBackError: string | undefined
            try {
                model = await _callEdamameTool("get_behavioral_model", {})
            } catch (e: any) {
                model = "{}"
                readBackError = String(e?.message || e)
            }
            let readBackOk = false
            try {
                const modelParsed = JSON.parse(model)
                readBackOk =
                    modelParsed &&
                    !modelParsed.error &&
                    (modelParsed.model !== null || Array.isArray(modelParsed.predictions))
            } catch { /* non-JSON is acceptable if upsert succeeded */ }

            return _asText(
                JSON.stringify({
                    success: true,
                    mode: "compiled",
                    sessions_processed: sessions.length,
                    session_keys: sessions.map((s) => s.key),
                    agent_type: agentType,
                    agent_instance_id: agentInstanceId,
                    read_back_ok: readBackOk,
                    ...(readBackError ? { readback_error: readBackError } : {}),
                    upsert_summary: upsertResult.slice(0, 500),
                }),
            )
        },
    })

    // Divergence detection -- verdicts are produced internally by edamame_core's
    // divergence engine; the gateway only exposes read-only query tools.
    api.registerTool({
        name: "get_divergence_verdict",
        description:
            "EDAMAME MCP: get the latest divergence detection verdict (CLEAN/DIVERGENCE/NO_MODEL/STALE). Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const { text, isError } = await _callEdamameToolSafe("get_divergence_verdict", {})
            return isError ? _asError(text) : _asText(text)
        },
    })

    api.registerTool({
        name: "get_divergence_history",
        description:
            "EDAMAME MCP: get rolling history of recent divergence verdicts. Read-only.",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                limit: { type: "integer", minimum: 1, maximum: 500 },
            },
        },
        async execute(_id: string, params: { limit?: number }) {
            const { text, isError } = await _callEdamameToolSafe("get_divergence_history", {
                limit: params.limit ?? 10,
            })
            return isError ? _asError(text) : _asText(text)
        },
    })

    // Conditional alert delivery via OpenClaw gateway messaging API.
    // Skills call this ONLY when their analysis warrants human attention.
    api.registerTool({
        name: "send_alert",
        description:
            "Send a WhatsApp/Telegram/etc alert via the OpenClaw gateway. " +
            "Use this ONLY when a security condition requires human attention " +
            "(divergence detected, escalated posture items, etc). " +
            "Do NOT call for routine CLEAN verdicts or all-clear reports.",
        parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
                message: {
                    type: "string",
                    minLength: 1,
                    description: "Alert body text to send.",
                },
                channel: {
                    type: "string",
                    description:
                        'Delivery channel (default: "whatsapp"). ' +
                        "Supports: whatsapp, telegram, discord, signal, slack, etc.",
                },
                to: {
                    type: "string",
                    description:
                        "Recipient in channel-native format (E.164 for WhatsApp/Signal, " +
                        "chat ID for Telegram, channel/user for Discord/Slack). " +
                        "When omitted, reads ALERT_TO env var.",
                },
            },
            required: ["message"],
        },
        async execute(
            _id: string,
            params: { message: string; channel?: string; to?: string },
        ) {
            const channel = params.channel || _getAlertChannel()
            const to = params.to || _getAlertTo()
            if (!to) {
                return _asError("No recipient. Set ALERT_TO env var or pass 'to' parameter.")
            }

            const { execSync } = require("node:child_process")
            const npmGlobal = path.join(process.env.HOME || "", ".npm-global", "bin")
            const localNode = path.join(process.env.HOME || "", ".local", "node-v22", "bin")
            const envPath = `${localNode}:${npmGlobal}:${process.env.PATH || ""}`

            const escapedMsg = params.message
                .replace(/\\/g, "\\\\")
                .replace(/"/g, '\\"')
                .replace(/\$/g, "\\$")
                .replace(/`/g, "\\`")

            const cmd =
                `openclaw message send --channel ${channel} ` +
                `-t "${to}" -m "${escapedMsg}"`

            try {
                const out = execSync(cmd, {
                    env: { ...process.env, PATH: envPath },
                    timeout: 30_000,
                    encoding: "utf-8",
                    stdio: ["pipe", "pipe", "pipe"],
                })
                return _asText(`Alert sent via ${channel} to ${to}:\n${out.trim()}`)
            } catch (e: any) {
                const stderr = e?.stderr || e?.message || String(e)
                return _asError(`sending alert: ${String(stderr).slice(0, 500)}`)
            }
        },
    })
}

