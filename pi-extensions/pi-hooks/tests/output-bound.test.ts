import { expect, test } from "bun:test";
import { readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { TOOL_CALL_LISTENER, TOOL_RESULT_LISTENER } from "../extensions/registry.ts";
import { initRustRepo, installCarrier, registerRendered, toolResultEvent, trusted, useIsolatedGitEnv } from "./harness.ts";

useIsolatedGitEnv();

/** What a hook prints past Pi's bound: one more line than the 2000 Pi keeps. */
const LINES = 2001;
const FULL = Array.from({ length: LINES }, (_, index) => `line-${index + 1}`).join("\n");
const SPEAKER = `seq 1 ${LINES} | sed 's/^/line-/' >&2; exit 2`;

/**
 * What reaches the model from an event's hooks keeps Pi's bound: the tail,
 * led by a notice naming the file that holds the whole text. A refusal's
 * reason on `tool_call` and the text appended to a tool result both take it.
 */
for (const row of [
	{ listener: TOOL_CALL_LISTENER },
	{ listener: TOOL_RESULT_LISTENER },
]) {
	test(`${row.listener} bounds what its hooks said`, async () => {
		const project = initRustRepo("pi-hooks-output-bound-");
		let saved: string | undefined;
		try {
			registerRendered(join(project, ".pi"), row.listener, "Bash", SPEAKER);
			const handler = installCarrier().handler(row.listener);
			let said: string;
			if (row.listener === TOOL_CALL_LISTENER) {
				const verdict = await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project)) as { block: true; reason: string };
				expect(verdict.block).toBe(true);
				said = verdict.reason;
			} else {
				const patched = await handler(toolResultEvent("bash", { command: "ls" }, "listing"), trusted(project)) as { content: { text: string }[] };
				expect(patched.content[0]?.text).toBe("listing");
				expect(patched.content).toHaveLength(2);
				said = patched.content[1]!.text;
			}
			const [notice, , ...tail] = said.split("\n");
			expect(notice?.startsWith("hook-output-truncated=")).toBe(true);
			saved = notice!.slice("hook-output-truncated=".length);
			expect(readFileSync(saved, "utf8")).toBe(FULL);
			expect(tail).toHaveLength(LINES - 1);
			expect(tail.join("\n")).toBe(FULL.slice(FULL.indexOf("\n") + 1));
		} finally {
			if (saved !== undefined) rmSync(saved, { force: true });
			rmSync(project, { recursive: true, force: true });
		}
	});
}
