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

export function _extractTraffic(text: string, commands: string[]): string[] {
    const hosts: string[] = []
    for (const u of _extractUrls(text)) {
        try {
            const url = new URL(u)
            const port = url.port || (url.protocol === "http:" ? "80" : "443")
            hosts.push(`${url.hostname}:${port}`)
        } catch {
            // Ignore malformed URLs when deriving expected traffic.
        }
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
        if (v) {
            const n = Number.parseInt(v, 10)
            if (n > 0 && n < 65536) ports.push(n)
        }
    }
    for (const cmd of commands) {
        const explicit = cmd.match(/--port(?:=|\s+)(\d{2,5})/)
        if (explicit?.[1]) ports.push(Number.parseInt(explicit[1], 10))
    }
    return [...new Set(ports.filter((p) => p > 0 && p < 65536))].sort((a, b) => a - b)
}

export function _extractPaths(text: string): string[] {
    const paths: string[] = []
    for (const m of text.matchAll(_PATH_RE)) {
        const cleaned = m[0].replace(/[,.:;]+$/, "")
        if (/\.git$/.test(cleaned) && !cleaned.startsWith("/") && !cleaned.startsWith("~")) continue
        paths.push(cleaned)
    }
    return _unique(paths)
}

export function _extractToolNames(text: string): string[] {
    const names: string[] = []
    for (const m of text.matchAll(_TOOL_CALL_RE)) if (m[1]) names.push(m[1].trim())
    return _unique(names)
}

export function _extractCommands(text: string): string[] {
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
    "~/.env", "~/.pgpass", "~/.pypirc", "~/.git-credentials",
    "~/.vault-token", "~/.azure/", "~/.my.cnf",
    "~/Library/Keychains/",
    "~/Library/Application Support/Google/Chrome/",
    "~/Library/Application Support/Chromium/",
    "~/Library/Application Support/Firefox/",
    "~/Library/Application Support/BraveSoftware/",
    "~/AppData/Local/Google/Chrome/",
    "~/AppData/Local/Chromium/",
    "~/AppData/Local/Mozilla/Firefox/",
    "~/AppData/Local/BraveSoftware/",
    "~/AppData/Roaming/Mozilla/Firefox/Profiles/",
    "~/AppData/Roaming/Microsoft/Credentials/",
    "~/AppData/Roaming/Microsoft/Protect/",
    "~/.config/google-chrome/", "~/.config/chromium/", "~/.mozilla/firefox/",
]

export function _isSensitivePath(p: string): boolean {
    const lower = p.toLowerCase()
    return _SENSITIVE_PATH_PATTERNS.some((pat) => lower.includes(pat)) ||
        /\.(env|pem|key|p12)$/i.test(p) || /credentials|token|psk/i.test(p)
}

export interface OpenClawSession {
    key: string
    title?: string
    messages: Array<{ role: string; content: string }>
    updatedAt?: string | number
    createdAt?: string | number
}

export function _toRfc3339(ts: string | number | undefined): string {
    if (ts == null) return new Date().toISOString()
    if (typeof ts === "number") return new Date(ts).toISOString()
    if (/^\d{10,}$/.test(ts)) return new Date(Number(ts)).toISOString()
    return ts
}

export function _buildSessionPayload(session: OpenClawSession): Record<string, unknown> {
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
            "*\\openclaw-gateway",
            "*\\bin\\openclaw",
            "*/lib/node_modules/openclaw",
            "*/.npm-global/",
        ],
        derived_expected_open_files: openFiles,
        source_path: "",
        started_at: _toRfc3339(session.createdAt),
        modified_at: _toRfc3339(session.updatedAt),
    }
}

export function _collapseRunSubSessions(sessions: OpenClawSession[]): OpenClawSession[] {
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

export function _buildRawPayload(
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
