import test from "node:test"
import assert from "node:assert/strict"
import register, {
    _callEdamameTool,
    _callEdamameToolSafe,
    _trimScorePayload,
    _trimSession,
    _filterGetSessionsPayload,
} from "../extensions/edamame/index.ts"

// Expected tool names registered by the OpenClaw plugin.
const EXPECTED_TOOL_NAMES = [
    "advisor_get_todos",
    "get_sessions",
    "get_anomalous_sessions",
    "get_blacklisted_sessions",
    "get_exceptions",
    "get_lan_devices",
    "get_lan_host_device",
    "get_breaches",
    "add_pwned_email",
    "remove_pwned_email",
    "get_pwned_emails",
    "set_lan_auto_scan",
    "get_score",
    "upsert_behavioral_model",
    "get_behavioral_model",
    "advisor_get_action_history",
    "agentic_process_todos",
    "agentic_get_workflow_status",
    "agentic_execute_action",
    "advisor_undo_action",
    "advisor_undo_all_actions",
    "upsert_behavioral_model_from_raw_sessions",
    "extrapolator_run_cycle",
    "get_divergence_verdict",
    "get_divergence_history",
    "send_alert",
]

// ── Tool registration ────────────────────────────────────────────────

test("register() registers all expected tool names", () => {
    const registered: Map<string, { description: string; parameters: unknown; execute: Function }> = new Map()
    const mockApi = {
        registerTool(descriptor: { name: string; description: string; parameters: unknown; execute: Function }) {
            registered.set(descriptor.name, descriptor)
        },
    }

    register(mockApi)

    for (const name of EXPECTED_TOOL_NAMES) {
        assert.ok(registered.has(name), `Tool '${name}' should be registered`)
    }
    assert.equal(registered.size, EXPECTED_TOOL_NAMES.length, `should register exactly ${EXPECTED_TOOL_NAMES.length} tools`)
})

test("each registered tool has a description and execute function", () => {
    const registered: Map<string, any> = new Map()
    const mockApi = {
        registerTool(descriptor: any) {
            registered.set(descriptor.name, descriptor)
        },
    }

    register(mockApi)

    for (const [name, descriptor] of registered) {
        assert.ok(typeof descriptor.description === "string" && descriptor.description.length > 0, `${name} should have a non-empty description`)
        assert.ok(typeof descriptor.execute === "function", `${name} should have an execute function`)
        assert.ok(descriptor.parameters && typeof descriptor.parameters === "object", `${name} should have parameters schema`)
    }
})

// ── _callEdamameTool error behavior ──────────────────────────────────

test("_callEdamameTool throws when no PSK is configured", async () => {
    const origHome = process.env.HOME
    const origPsk = process.env.EDAMAME_MCP_PSK
    process.env.HOME = "/nonexistent/path/for/test"
    delete process.env.EDAMAME_MCP_PSK
    try {
        await assert.rejects(
            () => _callEdamameTool("get_score", {}),
            (err: any) => {
                assert.ok(err instanceof Error)
                assert.ok(err.message.includes("missing EDAMAME MCP credential"))
                return true
            },
        )
    } finally {
        if (origHome !== undefined) process.env.HOME = origHome
        if (origPsk !== undefined) process.env.EDAMAME_MCP_PSK = origPsk
    }
})

test("_callEdamameToolSafe returns isError=true when no PSK is configured", async () => {
    const origHome = process.env.HOME
    const origPsk = process.env.EDAMAME_MCP_PSK
    process.env.HOME = "/nonexistent/path/for/test"
    delete process.env.EDAMAME_MCP_PSK
    try {
        const result = await _callEdamameToolSafe("get_score", {})
        assert.equal(result.isError, true)
        assert.ok(result.text.includes("missing EDAMAME MCP credential"))
    } finally {
        if (origHome !== undefined) process.env.HOME = origHome
        if (origPsk !== undefined) process.env.EDAMAME_MCP_PSK = origPsk
    }
})

// ── Response parsing helpers ─────────────────────────────────────────

test("_trimSession preserves essential fields and drops verbose ones", () => {
    const session = {
        session: { src_ip: "10.0.0.1", dst_ip: "1.2.3.4", dst_port: 443 },
        status: { active: true, extra_field: "dropped" },
        stats: {
            start_time: "2025-01-01T00:00:00Z",
            last_activity: "2025-01-01T01:00:00Z",
            inbound_bytes: 1000,
            outbound_bytes: 500,
            history: "ShAD",
            conn_state: "SF",
            verbose_field: "should_be_dropped",
        },
        l7: {
            pid: 1234,
            process_name: "curl",
            process_path: "/usr/bin/curl",
            cmd: "curl https://example.com",
        },
        dst_domain: "example.com",
        dst_service: "https",
        is_whitelisted: false,
        criticality: "high",
        uid: "abc123",
    }

    const trimmed = _trimSession(session)
    assert.equal(trimmed.session.dst_ip, "1.2.3.4")
    assert.equal(trimmed.status.active, true)
    assert.equal((trimmed.status as any).extra_field, undefined)
    assert.equal(trimmed.stats.start_time, "2025-01-01T00:00:00Z")
    assert.equal((trimmed.stats as any).verbose_field, undefined)
    assert.equal(trimmed.l7.pid, 1234)
    assert.equal(trimmed.l7.process_name, "curl")
    assert.equal(trimmed.dst_domain, "example.com")
    assert.equal(trimmed.uid, "abc123")
})

test("_trimScorePayload strips heavy threat fields", () => {
    const score = {
        overall: 90,
        stars: 4.5,
        network: 95,
        active: [
            {
                name: "firewall-disabled",
                severity: 3,
                description: "Long description text",
                implementation: "impl code",
                remediation: "remediation steps",
                rollback: "rollback steps",
            },
        ],
    }
    const result = JSON.parse(_trimScorePayload(JSON.stringify(score)))
    assert.equal(result.overall, 90)
    assert.equal(result.active[0].name, "firewall-disabled")
    assert.equal(result.active[0].description, undefined)
    assert.equal(result.active[0].implementation, undefined)
    assert.equal(result.active[0].remediation, undefined)
    assert.equal(result.active[0].rollback, undefined)
})

test("_filterGetSessionsPayload respects limit and active_only defaults", () => {
    const sessions = Array.from({ length: 300 }, (_, i) => ({
        status: { active: i % 2 === 0 },
        stats: { last_activity: `2025-01-${String((i % 28) + 1).padStart(2, "0")}T00:00:00Z` },
    }))
    const result = JSON.parse(_filterGetSessionsPayload(JSON.stringify(sessions), {}))
    // Default active_only=true, default limit=200
    assert.ok(result.length <= 200)
    assert.ok(result.every((s: any) => s.status.active === true))
})
