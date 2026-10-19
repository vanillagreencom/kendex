import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const packageDir = fileURLToPath(new URL("..", import.meta.url));
const scratch = join(packageDir, "tmp");
mkdirSync(scratch, { recursive: true });

const toolEvents = [
	{ type: "tool_execution_start", toolName: "read", args: { path: "live-read.txt" } },
	{ type: "message_end", message: { role: "toolResult", toolName: "read", content: [{ type: "text", text: "CODEX_BRIDGE_TOOL_OK_1658" }] } },
];
const final = (stopReason, text) => ({ type: "message_end", message: { role: "assistant", provider: "pi-codex", stopReason, content: [{ type: "text", text }] } });

for (const [name, events, passes] of [
	["the final pi-codex answer carries the value", [...toolEvents, final("stop", "CODEX_BRIDGE_TOOL_OK_1658")], true],
	["the final pi-codex message failed after the tool ran", [...toolEvents, final("toolUse", ""), final("error", "")], false],
	["the final pi-codex answer lacks the value", [...toolEvents, final("stop", "I could not read it")], false],
	["no read tool ran", [final("stop", "CODEX_BRIDGE_TOOL_OK_1658")], false],
]) {
	test(`the live smoke verdict: ${name}`, (t) => {
		const dir = mkdtempSync(join(scratch, "live-assert-"));
		t.after(() => rmSync(dir, { recursive: true, force: true }));
		const output = join(dir, "pi-output.jsonl");
		writeFileSync(output, events.map((event) => JSON.stringify(event)).join("\n"));
		const run = spawnSync(process.execPath, [join(packageDir, "tests", "assert-live-smoke.mjs"), output], { encoding: "utf8" });
		assert.equal(run.status === 0, passes, run.stderr);
	});
}
