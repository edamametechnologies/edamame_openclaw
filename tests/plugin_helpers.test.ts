import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
    _filterGetSessionsPayload,
    _trimScorePayload,
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
} from "../extensions/edamame/index.ts";
import type { GetSessionsArgs, OpenClawSession } from "../extensions/edamame/index.ts";

function withEnv(
    updates: Record<string, string | undefined>,
    fn: () => void,
) {
    const previous = new Map<string, string | undefined>();
    for (const [key, value] of Object.entries(updates)) {
        previous.set(key, process.env[key]);
        if (value === undefined) {
            delete process.env[key];
        } else {
            process.env[key] = value;
        }
    }
    try {
        fn();
    } finally {
        for (const [key, value] of previous.entries()) {
            if (value === undefined) {
                delete process.env[key];
            } else {
                process.env[key] = value;
            }
        }
    }
}

// ── _filterGetSessionsPayload ────────────────────────────────────────

test("filterGetSessionsPayload returns raw text on invalid JSON", () => {
    const raw = "not json";
    assert.equal(_filterGetSessionsPayload(raw, {}), raw);
});

test("filterGetSessionsPayload filters by active_only", () => {
    const sessions = [
        { status: { active: true }, stats: { last_activity: "2025-01-01T00:00:00Z" } },
        { status: { active: false }, stats: { last_activity: "2025-01-01T00:00:00Z" } },
    ];
    const result = JSON.parse(_filterGetSessionsPayload(JSON.stringify(sessions), { active_only: true }));
    assert.equal(result.length, 1);
    assert.equal(result[0].status.active, true);
});

test("filterGetSessionsPayload passes all when active_only is false", () => {
    const sessions = [
        { status: { active: true }, stats: { last_activity: "2025-01-01T00:00:00Z" } },
        { status: { active: false }, stats: { last_activity: "2025-01-01T00:00:00Z" } },
    ];
    const result = JSON.parse(_filterGetSessionsPayload(JSON.stringify(sessions), { active_only: false }));
    assert.equal(result.length, 2);
});

test("filterGetSessionsPayload filters by since timestamp", () => {
    const sessions = [
        { status: { active: true }, stats: { last_activity: "2025-06-01T00:00:00Z" } },
        { status: { active: true }, stats: { last_activity: "2025-01-01T00:00:00Z" } },
    ];
    const sinceMs = new Date("2025-03-01T00:00:00Z").getTime();
    const args: GetSessionsArgs = { active_only: false, since: sinceMs };
    const result = JSON.parse(_filterGetSessionsPayload(JSON.stringify(sessions), args));
    assert.equal(result.length, 1);
    assert.equal(result[0].stats.last_activity, "2025-06-01T00:00:00Z");
});

test("filterGetSessionsPayload respects limit", () => {
    const sessions = Array.from({ length: 10 }, (_, i) => ({
        status: { active: true },
        stats: { last_activity: `2025-01-${String(i + 1).padStart(2, "0")}T00:00:00Z` },
    }));
    const args: GetSessionsArgs = { active_only: false, limit: 3 };
    const result = JSON.parse(_filterGetSessionsPayload(JSON.stringify(sessions), args));
    assert.equal(result.length, 3);
});

test("filterGetSessionsPayload handles wrapped {sessions: [...]} format", () => {
    const payload = {
        sessions: [
            { status: { active: true }, stats: { last_activity: "2025-01-01T00:00:00Z" } },
            { status: { active: false }, stats: { last_activity: "2025-01-01T00:00:00Z" } },
        ],
        count: 2,
    };
    const result = JSON.parse(_filterGetSessionsPayload(JSON.stringify(payload), { active_only: true }));
    assert.ok(result.sessions);
    assert.equal(result.sessions.length, 1);
    assert.equal(result.count, 1);
});

// ── _trimScorePayload ────────────────────────────────────────────────

test("trimScorePayload returns raw text on invalid JSON", () => {
    assert.equal(_trimScorePayload("not json"), "not json");
});

test("trimScorePayload preserves score fields and trims threats", () => {
    const score = {
        overall: 85,
        stars: 4.25,
        network: 90,
        credentials: 80,
        system_integrity: 85,
        system_services: 88,
        applications: 82,
        active: [
            { name: "test-threat", severity: 3, description: "long desc", implementation: "impl code", remediation: "fix steps" },
        ],
        compliance: { tags: ["PCI-DSS"] },
    };
    const result = JSON.parse(_trimScorePayload(JSON.stringify(score)));
    assert.equal(result.overall, 85);
    assert.equal(result.stars, 4.25);
    assert.equal(result.active.length, 1);
    assert.equal(result.active[0].name, "test-threat");
    assert.equal(result.active[0].description, undefined);
    assert.equal(result.active[0].implementation, undefined);
    assert.equal(result.active[0].remediation, undefined);
});

// ── _buildSessionPayload ─────────────────────────────────────────────

test("buildSessionPayload extracts tool names and commands", () => {
    const session: OpenClawSession = {
        key: "test-session-1",
        title: "Test Session",
        messages: [
            {
                role: "user",
                content: "Run cargo test and check https://github.com/edamame",
            },
            {
                role: "assistant",
                content: "[Tool call] Shell\n  command: cargo test --release\n[Tool call] ReadFile\n  path: /src/main.rs",
            },
        ],
    };
    const payload = _buildSessionPayload(session);
    assert.equal(payload.session_key, "test-session-1");
    assert.ok(Array.isArray(payload.tool_names));
    assert.ok((payload.tool_names as string[]).includes("Shell"));
    assert.ok((payload.tool_names as string[]).includes("ReadFile"));
    assert.ok(Array.isArray(payload.commands));
    assert.ok((payload.commands as string[]).some((c: string) => c.includes("cargo test")));
    assert.ok(Array.isArray(payload.derived_expected_traffic));
    assert.ok((payload.derived_expected_traffic as string[]).some((t: string) => t.includes("github.com")));
});

// ── _buildRawPayload ─────────────────────────────────────────────────

test("buildRawPayload produces valid window structure", () => {
    const sessions: OpenClawSession[] = [
        {
            key: "s1",
            messages: [
                { role: "user", content: "hello" },
                { role: "assistant", content: "hi there" },
            ],
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T01:00:00Z",
        },
    ];
    const payload = _buildRawPayload(sessions, "openclaw", "gateway-1") as any;
    assert.equal(payload.agent_type, "openclaw");
    assert.equal(payload.agent_instance_id, "gateway-1");
    assert.equal(payload.source_kind, "openclaw");
    assert.ok(Array.isArray(payload.sessions));
    assert.equal(payload.sessions.length, 1);
    assert.ok(payload.window_start);
    assert.ok(payload.window_end);
});

test("normalizeAgentInstanceId strips macOS suffixes and punctuation", () => {
    assert.equal(_normalizeAgentInstanceId("Kralizec (2).local"), "kralizec");
    assert.equal(_normalizeAgentInstanceId("Gateway_Main"), "gateway-main");
});

test("isLegacyAgentInstanceId recognizes old extrapolator defaults", () => {
    assert.equal(_isLegacyAgentInstanceId("openclaw-default", "kralizec"), true);
    assert.equal(_isLegacyAgentInstanceId("main", "kralizec"), true);
    assert.equal(_isLegacyAgentInstanceId("kralizec-main", "kralizec"), true);
    assert.equal(_isLegacyAgentInstanceId("gateway-1", "kralizec"), false);
});

test("resolveAgentInstanceId migrates legacy runtime IDs to canonical host ID", () => {
    const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "edamame-openclaw-id-"));
    withEnv(
        {
            HOME: tempHome,
            EDAMAME_OPENCLAW_AGENT_INSTANCE_ID: undefined,
            EDAMAME_OPENCLAW_AGENT_HOSTNAME: "Kralizec",
        },
        () => {
            const resolved = _resolveAgentInstanceId("openclaw-default");
            assert.equal(resolved, "kralizec");
            const stored = fs.readFileSync(
                path.join(tempHome, ".edamame_openclaw_agent_instance_id"),
                "utf-8",
            );
            assert.equal(stored.trim(), "kralizec");
        },
    );
});

test("resolveAgentInstanceId preserves explicit non-legacy IDs", () => {
    const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "edamame-openclaw-id-"));
    withEnv(
        {
            HOME: tempHome,
            EDAMAME_OPENCLAW_AGENT_INSTANCE_ID: undefined,
            EDAMAME_OPENCLAW_AGENT_HOSTNAME: "Kralizec",
        },
        () => {
            const resolved = _resolveAgentInstanceId("gateway-1");
            assert.equal(resolved, "gateway-1");
        },
    );
});

test("resolveAgentInstanceId prefers persisted stable ID over later legacy prompts", () => {
    const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "edamame-openclaw-id-"));
    const idFile = path.join(tempHome, ".edamame_openclaw_agent_instance_id");
    fs.writeFileSync(idFile, "gateway-1\n");
    withEnv(
        {
            HOME: tempHome,
            EDAMAME_OPENCLAW_AGENT_INSTANCE_ID: undefined,
            EDAMAME_OPENCLAW_AGENT_HOSTNAME: "Kralizec",
        },
        () => {
            const resolved = _resolveAgentInstanceId("openclaw-default");
            assert.equal(resolved, "gateway-1");
        },
    );
});

// ── _collapseRunSubSessions ──────────────────────────────────────────

test("collapseRunSubSessions merges child run sessions into parent", () => {
    const sessions: OpenClawSession[] = [
        { key: "parent-1", messages: [{ role: "user", content: "start" }] },
        { key: "parent-1:run:0", messages: [{ role: "assistant", content: "step 1" }] },
        { key: "parent-1:run:1", messages: [{ role: "assistant", content: "step 2" }] },
        { key: "standalone", messages: [{ role: "user", content: "other" }] },
    ];
    const collapsed = _collapseRunSubSessions(sessions);
    assert.equal(collapsed.length, 2);
    const parent = collapsed.find((s) => s.key === "parent-1");
    assert.ok(parent);
    assert.equal(parent!.messages.length, 3);
});

// ── Extraction helpers ───────────────────────────────────────────────

test("extractTraffic detects URLs, domains, and package manager hosts", () => {
    const text = "Fetching https://api.openai.com/v1/chat and checking github.com";
    const commands = ["cargo build --release"];
    const traffic = _extractTraffic(text, commands);
    assert.ok(traffic.some((t) => t.includes("api.openai.com")));
    assert.ok(traffic.some((t) => t.includes("github.com")));
    assert.ok(traffic.some((t) => t.includes("crates.io")));
});

test("extractToolNames parses [Tool call] lines", () => {
    const text = "[Tool call] Shell\n  command: ls\n[Tool call] ReadFile\n  path: /tmp/x";
    const names = _extractToolNames(text);
    assert.deepEqual(names.sort(), ["ReadFile", "Shell"]);
});

test("extractCommands parses command: lines", () => {
    const text = "  command: cargo test\n  command: npm install";
    const cmds = _extractCommands(text);
    assert.ok(cmds.includes("cargo test"));
    assert.ok(cmds.includes("npm install"));
});

test("extractPaths finds file paths", () => {
    const text = "Reading /src/main.rs and ~/config/settings.json";
    const paths = _extractPaths(text);
    assert.ok(paths.some((p) => p.includes("src/main.rs")));
    assert.ok(paths.some((p) => p.includes("config/settings.json")));
});

test("isSensitivePath detects credential paths", () => {
    assert.ok(_isSensitivePath("~/.ssh/id_rsa"));
    assert.ok(_isSensitivePath("~/.aws/credentials"));
    assert.ok(_isSensitivePath("/tmp/secret.pem"));
    assert.ok(!_isSensitivePath("/src/main.rs"));
    assert.ok(!_isSensitivePath("/tmp/output.txt"));
});

// ── Timestamp helpers ────────────────────────────────────────────────

test("toEpochMs handles various timestamp formats", () => {
    assert.equal(_toEpochMs(1704067200000), 1704067200000);
    const isoMs = _toEpochMs("2024-01-01T00:00:00Z");
    assert.ok(isoMs !== null && isoMs > 0);
    assert.equal(_toEpochMs(undefined), null);
    assert.equal(_toEpochMs(null as any), null);
});

test("sessionActivityMs extracts from stats.last_activity", () => {
    const session = { stats: { last_activity: "2025-06-01T00:00:00Z" } };
    const ms = _sessionActivityMs(session);
    assert.ok(ms !== null && ms > 0);
});

test("toRfc3339 handles string, number, and undefined", () => {
    assert.ok(_toRfc3339("2025-01-01T00:00:00Z").includes("2025"));
    assert.ok(_toRfc3339(1704067200000).includes("202"));
    assert.ok(_toRfc3339(undefined).length > 0);
});
