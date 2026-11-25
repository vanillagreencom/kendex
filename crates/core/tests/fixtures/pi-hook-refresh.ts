// Drives the pi-hooks carrier's tool_call listener the way Pi does, over the
// calls the project refresh case in pi_carrier/project_refresh.rs judges, and
// prints the first line of each refusal, `null` for a call that passes.
import { unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [, , entry, cwd] = process.argv;
const { default: piHooks } = await import(entry);
let toolCall;
piHooks({
	on(event, callback) {
		if (event === "tool_call") toolCall = callback;
	},
});
if (typeof toolCall !== "function") throw new Error("the carrier registered no tool_call listener");

const ctx = {
	cwd,
	isProjectTrusted: () => true,
	sessionManager: {
		getSessionId: () => "refresh-session",
		getSessionFile: () => undefined,
	},
};
const firstLine = (verdict) => (verdict?.block === true ? verdict.reason.split("\n")[0] : null);
const bash = async (command: string) => firstLine(await toolCall({ toolName: "bash", input: { command } }, ctx));
const read = async () => firstLine(await toolCall({ toolName: "read", input: { path: "example.txt" } }, ctx));
const halt = join(process.env.FIXTURE_PROJECT, "halt");

const lines = [await bash("echo allowed"), await read(), await bash("echo configured-policy")];
writeFileSync(halt, "");
try {
	lines.push(await read());
} finally {
	unlinkSync(halt);
}
process.stdout.write(JSON.stringify(lines));
