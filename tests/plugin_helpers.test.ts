import test from "node:test";
import assert from "node:assert/strict";
import {
    _filterGetSessionsPayload,
    _trimScorePayload,
    _toEpochMs,
    _sessionActivityMs,
} from "../extensions/edamame/index.ts";
import type { GetSessionsArgs } from "../extensions/edamame/index.ts";

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
