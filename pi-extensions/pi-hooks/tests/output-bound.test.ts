import { expect, test } from "bun:test";
import { existsSync, readFileSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { TOOL_CALL_LISTENER, TOOL_RESULT_LISTENER, TURN_END_LISTENER } from "../extensions/registry.ts";
import { initRustRepo, installCarrier, registerRendered, toolResultEvent, trusted, useIsolatedGitEnv } from "./harness.ts";

useIsolatedGitEnv();

/** What a hook prints past Pi's bound: one more line than the 2000 Pi keeps. */
const LINES = 2001;
const FULL = Array.from({ length: LINES }, (_, index) => `line-${index + 1}`).join("\n");
const SPEAKER = `seq 1 ${LINES} | sed 's/^/line-/' >&2; exit 2`;

/** What an event's hooks said to the agent, read off the listener's answer. */
async function spoken(listener: string, project: string): Promise<string> {
	if (listener === TOOL_CALL_LISTENER) {
		const handler = installCarrier().handler(TOOL_CALL_LISTENER);
		const verdict = await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project)) as { block: true; reason: string };
		expect(verdict.block).toBe(true);
		return verdict.reason;
	}
	if (listener === TOOL_RESULT_LISTENER) {
		const handler = installCarrier().handler(TOOL_RESULT_LISTENER);
		const patched = await handler(toolResultEvent("bash", { command: "ls" }, "listing"), trusted(project)) as { content: { text: string }[] };
		expect(patched.content[0]?.text).toBe("listing");
		expect(patched.content).toHaveLength(2);
		return patched.content[1]!.text;
	}
	// `Stop` registrations sit under the `turn_end` key and run at the settle
	// boundary, where what they said is the one entry the carrier appends.
	const handler = installCarrier().handler("agent_before_settle");
	const settled = await handler({ type: "agent_before_settle", entries: [], continue: false, outcome: "completed" }, trusted(project)) as { entries: { content: string }[] };
	expect(settled.entries).toHaveLength(1);
	return settled.entries[0]!.content;
}

/**
 * What reaches the model from an event's hooks keeps Pi's bound: the tail,
 * led by a notice naming the file that holds the whole text. A refusal's
 * reason on `tool_call`, the text appended to a tool result and a `Stop`
 * entry all take it. A system temporary directory that does not exist is
 * one the file cannot be written to, and the notice says so instead.
 */
for (const row of [
	{ listener: TOOL_CALL_LISTENER, tmp: "writable" },
	{ listener: TOOL_RESULT_LISTENER, tmp: "writable" },
	{ listener: TURN_END_LISTENER, tmp: "writable" },
	{ listener: TOOL_RESULT_LISTENER, tmp: "missing" },
] as const) {
	test(`${row.listener} bounds what its hooks said, ${row.tmp} temporary directory`, async () => {
		const project = initRustRepo("pi-hooks-output-bound-");
		const savedTmp = process.env.TMPDIR;
		let saved: string | undefined;
		try {
			registerRendered(join(project, ".pi"), row.listener, row.listener === TURN_END_LISTENER ? undefined : "Bash", SPEAKER);
			if (row.tmp === "missing") process.env.TMPDIR = join(project, "no-such-dir");
			let said: string;
			try {
				said = await spoken(row.listener, project);
			} finally {
				if (savedTmp === undefined) delete process.env.TMPDIR;
				else process.env.TMPDIR = savedTmp;
			}
			const [notice, , ...tail] = said.split("\n");
			if (row.tmp === "writable") {
				expect(notice?.startsWith("hook-output-truncated=")).toBe(true);
				saved = notice!.slice("hook-output-truncated=".length);
				expect(readFileSync(saved, "utf8")).toBe(FULL);
				if (process.platform !== "win32") expect(statSync(saved).mode & 0o077).toBe(0);
			} else {
				expect(notice?.startsWith("hook-output-unsaved=")).toBe(true);
				expect(existsSync(join(project, "no-such-dir"))).toBe(false);
			}
			expect(tail).toHaveLength(LINES - 1);
			expect(tail.join("\n")).toBe(FULL.slice(FULL.indexOf("\n") + 1));
		} finally {
			if (saved !== undefined) rmSync(saved, { force: true });
			rmSync(project, { recursive: true, force: true });
		}
	});
}
