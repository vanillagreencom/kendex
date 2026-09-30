import { expect, spyOn, test } from "bun:test";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { TOOL_CALL_LISTENER, TOOL_RESULT_LISTENER } from "../extensions/registry.ts";
import { initRustRepo, installCarrier, readLog, registerRendered, renderStub, toolResultEvent, trusted, useIsolatedGitEnv, writePiConfig } from "./harness.ts";

import * as vocab from "../extensions/vocab.ts";

useIsolatedGitEnv();

/**
 * A hook's payload is built only once a hook is about to read it, and once
 * for every hook on the event. `claudeToolInput` keys the tool's input into
 * both payloads, so its call count is the count of payloads built. An event
 * no registration matches, and one whose only match is a guard switched off,
 * builds none.
 */
for (const row of [
	{ name: "tool_call with no matching hook", listener: TOOL_CALL_LISTENER, hooks: "other-tool", built: 0 },
	{ name: "tool_result with no matching hook", listener: TOOL_RESULT_LISTENER, hooks: "other-tool", built: 0 },
	{ name: "tool_call whose only match is switched off", listener: TOOL_CALL_LISTENER, hooks: "guard-off", built: 0 },
	{ name: "tool_call with two matching hooks", listener: TOOL_CALL_LISTENER, hooks: "two", built: 1 },
	{ name: "tool_result with two matching hooks", listener: TOOL_RESULT_LISTENER, hooks: "two", built: 1 },
]) {
	test(`payload: ${row.name}`, async () => {
		const project = initRustRepo("pi-hooks-lazy-payload-");
		const log = join(project, "payload.log");
		const keyed = spyOn(vocab, "claudeToolInput");
		try {
			const pi = join(project, ".pi");
			switch (row.hooks) {
				case "other-tool":
					registerRendered(pi, row.listener, "Write", `cat >> ${JSON.stringify(log)}`);
					break;
				case "guard-off":
					writePiConfig(project, { blockBareCd: false });
					renderStub(project, "block-bare-cd", { exitCode: 0, log });
					break;
				case "two":
					registerRendered(pi, row.listener, "Bash", `cat >> ${JSON.stringify(log)}; echo >> ${JSON.stringify(log)}`);
					registerRendered(pi, row.listener, "Bash", `cat >> ${JSON.stringify(log)}; echo >> ${JSON.stringify(log)}`);
					break;
				default:
					throw new Error(`no fixture for ${row.hooks}`);
			}
			const handler = installCarrier().handler(row.listener);
			const event = row.listener === TOOL_CALL_LISTENER
				? { toolName: "bash", input: { command: "ls" } }
				: toolResultEvent("bash", { command: "ls" }, "listing");
			expect(await handler(event, trusted(project))).toBeUndefined();
			expect(keyed).toHaveBeenCalledTimes(row.built);
			const payloads = readLog(log).split("\n").filter((line) => line !== "");
			expect(payloads).toHaveLength(row.hooks === "two" ? 2 : 0);
			if (row.hooks === "two") expect(payloads[1]).toBe(payloads[0]);
		} finally {
			keyed.mockRestore();
			rmSync(project, { recursive: true, force: true });
		}
	});
}
