import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { resolveConfig, runHealthcheck } from "../service/health.mjs";

test("each healthcheck tool call ends the MCP session it opened", async () => {
    let opened = 0;
    const deleted: string[] = [];
    const server = http.createServer((request, response) => {
        if (request.method === "DELETE") {
            deleted.push(String(request.headers["mcp-session-id"] || ""));
            response.writeHead(200);
            response.end();
            return;
        }
        let body = "";
        request.on("data", (chunk) => {
            body += String(chunk);
        });
        request.on("end", () => {
            const message = JSON.parse(body || "{}");
            if (message.method === "initialize") {
                opened += 1;
                response.writeHead(200, {
                    "Content-Type": "application/json",
                    "Mcp-Session-Id": `sess-${opened}`,
                });
                response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: { protocolVersion: "2025-11-25" } }));
            } else if (message.id === undefined) {
                response.writeHead(202);
                response.end();
            } else {
                response.writeHead(200, { "Content-Type": "application/json" });
                response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: { content: [{ type: "text", text: "{}" }] } }));
            }
        });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "edamame-openclaw-health-"));
    try {
        await fs.writeFile(path.join(home, ".edamame_psk"), "test-psk-0123456789abcdef0123456789abcdef\n");
        const address = server.address() as { port: number };
        const config = resolveConfig({ home, endpoint: `http://127.0.0.1:${address.port}/mcp` });
        await runHealthcheck(config, {});
        assert.ok(opened > 0, "the healthcheck opened sessions");
        assert.equal(deleted.length, opened);
        assert.deepEqual(
            [...deleted].sort(),
            Array.from({ length: opened }, (_, i) => `sess-${i + 1}`).sort(),
        );
    } finally {
        await fs.rm(home, { recursive: true, force: true });
        await new Promise<void>((resolve) => server.close(() => resolve()));
    }
});
