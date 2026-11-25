import assert from "node:assert/strict";
import { writeFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";

const [, , entry, cwd] = process.argv;
const { default: piHooks } = await import(entry);
let toolCall;
piHooks({
	on(event, callback) {
		if (event === "tool_call") toolCall = callback;
	},
});
assert.equal(typeof toolCall, "function");

const ctx = {
	cwd,
	isProjectTrusted: () => true,
	sessionManager: {
		getSessionId: () => "refresh-session",
		getSessionFile: () => undefined,
	},
};
const bash = (command: string) => toolCall({ toolName: "bash", input: { command } }, ctx);
const read = () => toolCall({ toolName: "read", input: { path: "example.txt" } }, ctx);
const firstLine = (verdict) => verdict?.block === true ? verdict.reason.split("\n")[0] : undefined;
const halt = join(process.env.FIXTURE_PROJECT, "halt");

assert.equal(await bash("echo allowed"), undefined);
assert.equal(await read(), undefined);
const policy = firstLine(await bash("echo configured-policy"));
writeFileSync(halt, "");
try {
	const hold = firstLine(await read());
	assert.deepEqual([policy, hold], ["command-safety: refused=policy", "lane-mail-check: halt=fixture"]);
} finally {
	unlinkSync(halt);
}
