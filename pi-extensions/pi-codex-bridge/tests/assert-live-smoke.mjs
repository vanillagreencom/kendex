// Judges the JSON event stream of the live smoke run (`pi --mode json`). Pi
// exits 0 in JSON mode even when its last assistant message failed, and its
// own tool events carry the fixture value before Codex ever sees it, so the
// verdict rests on the final pi-codex assistant message.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const FIXTURE_VALUE = "CODEX_BRIDGE_TOOL_OK_1658";
const outputPath = process.argv[2];
assert.ok(outputPath, "output path is required");
const events = readFileSync(outputPath, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));

function objects(value) {
	if (value === null || typeof value !== "object") return [];
	if (Array.isArray(value)) return value.flatMap(objects);
	return [value, ...Object.values(value).flatMap(objects)];
}

assert.ok(events.flatMap(objects).some((value) => value.toolName === "read"), "live Pi output has no read tool execution");
const finals = events.filter((event) => event.type === "message_end" && event.message?.role === "assistant" && event.message.provider === "pi-codex").map((event) => event.message);
assert.ok(finals.length > 0, "live Pi output has no pi-codex assistant message");
const final = finals.at(-1);
assert.equal(final.stopReason, "stop", `the final pi-codex message ended ${final.stopReason}: ${final.errorMessage ?? ""}`);
const text = (final.content ?? []).filter((item) => item.type === "text").map((item) => item.text).join("\n");
assert.ok(text.includes(FIXTURE_VALUE), "the final pi-codex answer does not carry the fixture value");
console.log("hosted-tool-call provider=pi-codex tool=read result=ok");
