import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const outputPath = process.argv[2];
assert.ok(outputPath, "output path is required");
const lines = readFileSync(outputPath, "utf8").split("\n").filter(Boolean);
const events = lines.map((line) => JSON.parse(line));

function objects(value) {
	if (value === null || typeof value !== "object") return [];
	if (Array.isArray(value)) return value.flatMap(objects);
	return [value, ...Object.values(value).flatMap(objects)];
}

const all = events.flatMap(objects);
assert.ok(all.some((value) => value.toolName === "read"), "live Pi output has no read tool execution");
assert.ok(lines.some((line) => line.includes("CODEX_BRIDGE_TOOL_OK_1658")), "live Pi output lacks the fixture value");
console.log("hosted-tool-call provider=pi-codex tool=read result=ok");
