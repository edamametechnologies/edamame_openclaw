import fs from "node:fs"
import path from "node:path"

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
                    name: "edamame_openclaw-edamame-mcp",
                    version: "0.1.0",
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
    if (!client) return "ERROR: missing EDAMAME MCP PSK (~/.edamame_psk or EDAMAME_MCP_PSK)"

    try {
        return await client.callTool(toolName, kvArgs, timeoutMs)
    } catch (e: any) {
        const msg = String(e?.message || e)
        return `ERROR: ${msg}`
    }
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

// ── Deterministic session-to-raw-payload extraction ──────────────────
// Ported from edamame_cursor/adapters/session_prediction_adapter.mjs.
// Builds a RawReasoningSessionPayload from OpenClaw session transcripts
// and forwards it to EDAMAME's upsert_behavioral_model_from_raw_sessions,
// which uses EDAMAME's internal LLM instead of the OpenClaw agent LLM.

const _URL_RE = /\bhttps?:\/\/[^\s"'`)>]+/g
const _DOMAIN_RE = /\b((?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:com|org|net|io|dev|tech|cloud|co|info|biz|us|uk|eu|fr|de|app|xyz|me|ai|security|local))\b/gi
const _PORT_RE = /\b(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d{2,5})\b|\bport\s+(\d{2,5})\b|\b--port(?:=|\s+)(\d{2,5})\b/gi
const _GIT_REMOTE_RE = /\bgit@([A-Za-z0-9.-]+):([^\s"'`)>]+)/g
const _PATH_RE = /(?:~\/[^\s"'`)>]+|\/[^\s"'`)>]+|[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.@-]+)+(?:\.[A-Za-z0-9_-]+)?)/g
const _TOOL_CALL_RE = /^\[Tool call\]\s*(.+)$/gm
const _COMMAND_RE = /^\s*command:\s*(.+)$/gm
const _FILE_EXT_BLACKLIST = /\.(rs|py|js|ts|dart|md|toml|yaml|yml|json|html|css)$/

function _unique(arr: string[]): string[] {
    return [...new Set(arr.filter(Boolean).map((s) => s.trim()))].filter(Boolean)
}

function _extractUrls(text: string): string[] {
    return _unique((text.match(_URL_RE) || []))
}

function _extractDomains(text: string): string[] {
    const hosts: string[] = []
    for (const m of text.matchAll(_DOMAIN_RE)) {
        const d = m[1].toLowerCase()
        if (!d.includes(".") || _FILE_EXT_BLACKLIST.test(d)) continue
        hosts.push(d)
    }
    return _unique(hosts)
}

function _extractTraffic(text: string, commands: string[]): string[] {
    const hosts: string[] = []
    for (const u of _extractUrls(text)) {
        try {
            const url = new URL(u)
            const port = url.port || (url.protocol === "http:" ? "80" : "443")
            hosts.push(`${url.hostname}:${port}`)
        } catch { /* ignore */ }
    }
    for (const m of text.matchAll(_GIT_REMOTE_RE)) {
        if (m[1]) hosts.push(`${m[1]}:22`)
    }
    for (const d of _extractDomains(text)) hosts.push(`${d}:443`)
    for (const cmd of commands) {
        const lower = cmd.toLowerCase()
        if (lower.includes("cargo ")) hosts.push("crates.io:443", "github.com:443")
        if (/\bnpm |pnpm |yarn /.test(lower)) hosts.push("registry.npmjs.org:443")
        if (/\bpip |python.*-m pip/.test(lower)) hosts.push("pypi.org:443")
        if (/\bgit (clone|fetch|pull)/.test(lower)) hosts.push("github.com:443")
        const curlUrl = cmd.match(/https?:\/\/([a-zA-Z0-9.-]+)/)
        if (curlUrl?.[1] && /\bcurl |wget /.test(lower)) hosts.push(`${curlUrl[1].toLowerCase()}:443`)
    }
    return _unique(hosts)
}

function _extractPorts(text: string, commands: string[]): number[] {
    const ports: number[] = []
    for (const m of text.matchAll(_PORT_RE)) {
        const v = m.slice(1).find(Boolean)
        if (v) { const n = Number.parseInt(v, 10); if (n > 0 && n < 65536) ports.push(n) }
    }
    for (const cmd of commands) {
        const explicit = cmd.match(/--port(?:=|\s+)(\d{2,5})/)
        if (explicit?.[1]) ports.push(Number.parseInt(explicit[1], 10))
    }
    return [...new Set(ports.filter((p) => p > 0 && p < 65536))].sort((a, b) => a - b)
}

function _extractPaths(text: string): string[] {
    const paths: string[] = []
    for (const m of text.matchAll(_PATH_RE)) paths.push(m[0].replace(/[,.:;]+$/, ""))
    return _unique(paths)
}

function _extractToolNames(text: string): string[] {
    const names: string[] = []
    for (const m of text.matchAll(_TOOL_CALL_RE)) if (m[1]) names.push(m[1].trim())
    return _unique(names)
}

function _extractCommands(text: string): string[] {
    const cmds: string[] = []
    for (const m of text.matchAll(_COMMAND_RE)) if (m[1]) cmds.push(m[1].trim())
    return _unique(cmds)
}

function _inferProcessPaths(commands: string[]): string[] {
    const patterns: string[] = []
    for (const cmd of commands) {
        const bin = cmd.trim().split(/\s+/)[0]
        if (bin) patterns.push(bin.startsWith("/") ? bin : `*/${bin.toLowerCase()}`)
    }
    return _unique(patterns)
}

const _SENSITIVE_PATH_PATTERNS = [
    "~/.ssh/", "~/.aws/", "~/.config/gcloud/", "~/.kube/", "~/.gnupg/",
    "~/.docker/config.json", "~/.npmrc", "~/.netrc",
]

function _isSensitivePath(p: string): boolean {
    const lower = p.toLowerCase()
    return _SENSITIVE_PATH_PATTERNS.some((pat) => lower.includes(pat)) ||
        /\.(env|pem|key|p12)$/i.test(p) || /credentials|token|psk/i.test(p)
}

interface OpenClawSession {
    key: string
    title?: string
    messages: Array<{ role: string; content: string }>
    updatedAt?: string | number
    createdAt?: string | number
}

function _toRfc3339(ts: string | number | undefined): string {
    if (ts == null) return new Date().toISOString()
    if (typeof ts === "number") return new Date(ts).toISOString()
    if (/^\d{10,}$/.test(ts)) return new Date(Number(ts)).toISOString()
    return ts
}

function _buildSessionPayload(session: OpenClawSession): Record<string, unknown> {
    const userParts: string[] = []
    const assistantParts: string[] = []
    for (const msg of session.messages || []) {
        const text = typeof msg.content === "string" ? msg.content : JSON.stringify(msg.content)
        if (msg.role === "user") userParts.push(text)
        else if (msg.role === "assistant") assistantParts.push(text)
    }
    const userText = userParts.join("\n\n")
    const assistantText = assistantParts.join("\n\n")
    const combinedText = [userText, assistantText].filter(Boolean).join("\n\n")

    const toolNames = _extractToolNames(combinedText)
    const commands = _extractCommands(combinedText)
    const paths = _extractPaths(combinedText)
    const traffic = _extractTraffic(combinedText, commands)
    const ports = _extractPorts(combinedText, commands)
    const processPaths = _inferProcessPaths(commands)
    const sensitivePaths = paths.filter(_isSensitivePath)
    const openFiles = paths.filter((p) => !_isSensitivePath(p))

    return {
        session_key: session.key,
        title: session.title || `OpenClaw session ${session.key}`,
        user_text: userText,
        assistant_text: assistantText,
        raw_text: combinedText,
        tool_names: toolNames,
        commands,
        derived_expected_traffic: traffic,
        derived_expected_local_open_ports: ports,
        derived_expected_process_paths: processPaths,
        derived_expected_parent_paths: [],
        derived_expected_grandparent_paths: [],
        derived_scope_process_paths: [],
        derived_scope_parent_paths: [],
        derived_scope_grandparent_paths: [],
        derived_scope_any_lineage_paths: [
            "*/openclaw-gateway",
            "*/bin/openclaw",
        ],
        derived_expected_open_files: openFiles,
        source_path: "",
        started_at: _toRfc3339(session.createdAt),
        modified_at: _toRfc3339(session.updatedAt),
    }
}

function _collapseRunSubSessions(sessions: OpenClawSession[]): OpenClawSession[] {
    const RUN_SEP = ":run:"
    const parentMap = new Map<string, OpenClawSession>()
    const orphans: OpenClawSession[] = []

    for (const s of sessions) {
        const runIdx = s.key.indexOf(RUN_SEP)
        if (runIdx === -1) {
            parentMap.set(s.key, { ...s, messages: [...s.messages] })
        }
    }

    for (const s of sessions) {
        const runIdx = s.key.indexOf(RUN_SEP)
        if (runIdx === -1) continue
        const parentKey = s.key.slice(0, runIdx)
        const parent = parentMap.get(parentKey)
        if (parent) {
            parent.messages.push(...s.messages)
            const childUpdated = _toRfc3339(s.updatedAt)
            const parentUpdated = _toRfc3339(parent.updatedAt)
            if (childUpdated > parentUpdated) parent.updatedAt = s.updatedAt
        } else {
            orphans.push(s)
        }
    }

    return [...parentMap.values(), ...orphans]
}

function _buildRawPayload(
    sessions: OpenClawSession[],
    agentType: string,
    agentInstanceId: string,
): Record<string, unknown> {
    const now = new Date()
    const sessionPayloads = sessions.map(_buildSessionPayload)
    const windowStart = sessionPayloads.reduce(
        (earliest, s) => {
            const t = s.started_at as string
            return t < earliest ? t : earliest
        },
        sessionPayloads[0]?.started_at as string || now.toISOString(),
    )
    const windowEnd = sessionPayloads.reduce(
        (latest, s) => {
            const t = s.modified_at as string
            return t > latest ? t : latest
        },
        sessionPayloads[0]?.modified_at as string || now.toISOString(),
    )

    return {
        window_start: windowStart,
        window_end: windowEnd,
        agent_type: agentType,
        agent_instance_id: agentInstanceId,
        source_kind: "openclaw",
        sessions: sessionPayloads,
    }
}

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
}
export type { GetSessionsArgs, OpenClawSession }

export default function register(api: any) {
    // Read-only surfaces used by the two-plane monitor + benchmark harness.
    api.registerTool({
        name: "advisor_get_todos",
        description: "EDAMAME MCP: list all security findings (todos). Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const out = await _callEdamameTool("advisor_get_todos", {})
            return _asText(out)
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

            const out = await _callEdamameTool("get_sessions", upstreamArgs)
            return _asText(_filterGetSessionsPayload(out, params))
        },
    })

    api.registerTool({
        name: "get_anomalous_sessions",
        description:
            "EDAMAME MCP: get sessions flagged as statistically anomalous. High-value signal for detecting prompt injection or data exfiltration. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const out = await _callEdamameTool("get_anomalous_sessions", {})
            return _asText(_trimSessionList(out))
        },
    })

    api.registerTool({
        name: "get_blacklisted_sessions",
        description:
            "EDAMAME MCP: get sessions to known-malicious destinations. Highest-confidence signal — any match indicates compromise. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const out = await _callEdamameTool("get_blacklisted_sessions", {})
            return _asText(_trimSessionList(out))
        },
    })

    api.registerTool({
        name: "get_exceptions",
        description:
            "EDAMAME MCP: get sessions violating whitelist/policy rules. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const out = await _callEdamameTool("get_exceptions", {})
            return _asText(_trimSessionList(out))
        },
    })

    // Multi-dimensional observation: LAN, Identity, and Posture Score.
    api.registerTool({
        name: "get_lan_devices",
        description:
            "EDAMAME MCP: get all discovered LAN devices with IPs, open ports, CVEs, OS fingerprints. Enables lateral-movement detection. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const out = await _callEdamameTool("get_lan_devices", {})
            return _asText(out)
        },
    })

    api.registerTool({
        name: "get_lan_host_device",
        description:
            "EDAMAME MCP: get this host's own device info as seen by the LAN scanner — IPs, MAC, open ports, OS fingerprint. Enables vulnerability detection: detect internet-exposed services (e.g. STRIKE-class exposed gateways) before an attacker connects. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const out = await _callEdamameTool("get_lan_host_device", {})
            return _asText(out)
        },
    })

    api.registerTool({
        name: "get_breaches",
        description:
            "EDAMAME MCP: get HIBP breach data for all monitored identities. Enables credential-stuffing detection. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const out = await _callEdamameTool("get_breaches", {})
            return _asText(out)
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
            const out = await _callEdamameTool("add_pwned_email", { email: params.email })
            return _asText(out)
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
            const out = await _callEdamameTool("remove_pwned_email", { email: params.email })
            return _asText(out)
        },
    })

    api.registerTool({
        name: "get_pwned_emails",
        description:
            "EDAMAME MCP: list all emails currently monitored for HIBP breaches with per-email summary and breach counts. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const out = await _callEdamameTool("get_pwned_emails", {})
            return _asText(out)
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
            const out = await _callEdamameTool("set_lan_auto_scan", { enabled: params.enabled })
            return _asText(out)
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
            const out = await _callEdamameTool("get_score", { full: params.full === true })
            if (params.full) return _asText(out)
            return _asText(_trimScorePayload(out))
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
                return _asText("ERROR: missing window_json (or window object) payload")
            }
            const out = await _callEdamameTool("upsert_behavioral_model", {
                window_json: payload,
            })
            return _asText(out)
        },
    })

    api.registerTool({
        name: "get_behavioral_model",
        description:
            "EDAMAME MCP: fetch the current behavioral model used by the divergence engine. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const out = await _callEdamameTool("get_behavioral_model", {})
            return _asText(out)
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
            const out = await _callEdamameTool("advisor_get_action_history", { limit: params.limit ?? 50 })
            return _asText(out)
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
            const out = await _callEdamameTool("agentic_process_todos", {
                confirmation_level: params.confirmation_level ?? "manual",
            })
            return _asText(out)
        },
    })

    api.registerTool({
        name: "agentic_get_workflow_status",
        description: "EDAMAME MCP: get current agentic workflow status. Read-only.",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const out = await _callEdamameTool("agentic_get_workflow_status", {})
            return _asText(out)
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
            const out = await _callEdamameTool("agentic_execute_action", { action_id: params.action_id })
            return _asText(out)
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
            const out = await _callEdamameTool("advisor_undo_action", { action_id: params.action_id })
            return _asText(out)
        },
    })

    api.registerTool({
        name: "advisor_undo_all_actions",
        description: "EDAMAME MCP: undo all actions from current session (SIDE EFFECTS).",
        parameters: { type: "object", additionalProperties: false, properties: {} },
        async execute(_id: string, _params: Record<string, never>) {
            const out = await _callEdamameTool("advisor_undo_all_actions", {})
            return _asText(out)
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
            const out = await _callEdamameTool("upsert_behavioral_model_from_raw_sessions", {
                raw_sessions_json: params.raw_sessions_json,
            }, { timeoutMs: 120_000 })
            return _asText(out)
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
                        "Stable identifier for this OpenClaw deployment (default: hostname or 'openclaw-default').",
                },
            },
        },
        async execute(
            _id: string,
            params: { active_minutes?: number; agent_instance_id?: string },
        ) {
            const activeMinutes = params.active_minutes ?? 15
            const agentType = "openclaw"
            const agentInstanceId =
                params.agent_instance_id ||
                (process.env.HOSTNAME || "").trim() ||
                "openclaw-default"

            // Step 1: Enumerate recent sessions via OpenClaw CLI
            const { execSync } = require("node:child_process")
            const fs = require("node:fs")
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
                return _asText(
                    `ERROR: Failed to enumerate OpenClaw sessions: ${String(e?.stderr || e?.message || e).slice(0, 500)}`,
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
                    version: "3.0",
                    hash: "",
                    ingested_at: now.toISOString(),
                }

                const heartbeatResult = await _callEdamameTool(
                    "upsert_behavioral_model",
                    { window_json: JSON.stringify(heartbeatWindow) },
                    { timeoutMs: 30_000 },
                )

                return _asText(
                    JSON.stringify({
                        success: true,
                        mode: "compiled",
                        sessions_processed: 0,
                        reason: "heartbeat",
                        agent_type: agentType,
                        agent_instance_id: agentInstanceId,
                        upsert_summary: String(heartbeatResult).slice(0, 500),
                    }),
                )
            }

            // Step 2: Build raw payload deterministically
            const rawPayload = _buildRawPayload(sessions, agentType, agentInstanceId)

            // Step 3: Forward to EDAMAME's internal LLM
            const rawJson = JSON.stringify(rawPayload)
            const upsertResult = await _callEdamameTool(
                "upsert_behavioral_model_from_raw_sessions",
                { raw_sessions_json: rawJson },
                { timeoutMs: 120_000 },
            )

            if (upsertResult.startsWith("ERROR:")) {
                return _asText(
                    JSON.stringify({
                        success: false,
                        mode: "compiled",
                        sessions_processed: sessions.length,
                        error: upsertResult,
                    }),
                )
            }

            // Step 4: Verify read-back
            const model = await _callEdamameTool("get_behavioral_model", {})
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
            const out = await _callEdamameTool("get_divergence_verdict", {})
            return _asText(out)
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
            const out = await _callEdamameTool("get_divergence_history", {
                limit: params.limit ?? 10,
            })
            return _asText(out)
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
                return _asText(
                    "ERROR: No recipient. Set ALERT_TO env var or pass 'to' parameter.",
                )
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
                return _asText(`ERROR sending alert: ${stderr.slice(0, 500)}`)
            }
        },
    })
}

