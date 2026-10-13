import { afterAll, expect, test } from "bun:test";
import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createHarness, installExtension, teardown } from "../../pi-agents-tmux/tests/extension-fixture.ts";
import { cleanupTempRuntimes, importRuntimeCopy, writeRuntimeCopy } from "../../pi-agents-tmux/tests/browser-fixture.ts";
import { runtimeDirForContext } from "../../pi-agents-tmux/extensions/subagent/settings.ts";
import { taskRegistryPath } from "../../pi-agents-tmux/extensions/subagent/paths.ts";
import { writeTaskRegistry } from "../../pi-agents-tmux/extensions/subagent/tasks.ts";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { PaneTaskStatus } from "../../pi-agents-tmux/extensions/subagent/types.ts";
import { TURN_END_LISTENER } from "../extensions/registry.ts";
import { initRustRepo, installCarrier, mutatedCarrier, readLog, registerRendered, trusted, useIsolatedGitEnv } from "./harness.ts";

useIsolatedGitEnv();
afterAll(cleanupTempRuntimes);

const STATS = Symbol.for("kendex.pi.agents");
const globals = globalThis as Record<symbol, unknown>;

async function assertPayloadCounts(carrier?: (pi: never) => void, producer?: Parameters<typeof installExtension>[1]): Promise<void> {
	const project = initRustRepo("pi-hooks-working-agents-");
	const harness = createHarness({});
	const prior = globals[STATS];
	try {
		await installExtension(harness, producer);
		const log = join(project, "stop.json");
		registerRendered(join(project, ".pi"), TURN_END_LISTENER, undefined, `cat > ${JSON.stringify(log)}`);
		const ctx = trusted(project, { hasUI: true, ui: { notify: () => undefined } }) as unknown as ExtensionContext;
		const root = runtimeDirForContext(ctx);
		const other = runtimeDirForContext({ ...ctx, sessionManager: { ...ctx.sessionManager, getSessionId: () => "other-lane" } });
		// Another lane's working agent cannot keep this session working.
		await writeTaskRegistry(other, { other: { agent: "scout", taskId: "other", task: "map", kind: "pane", status: "running" } });
		const settle = installCarrier(undefined, carrier).handler("agent_before_settle");
		const check = async (want: number | null) => {
			await settle({ outcome: "completed" }, ctx as unknown as Record<string, unknown>);
			expect(JSON.parse(readLog(log)).working_agents).toBe(want);
		};
		await check(0);
		for (const [status, want] of [
			["queued", 1], ["running", 1], ["completed", 0], ["blocked", 0],
			["failed", 0], ["stopped", 0], ["refused", 0], ["needs_completion", 0], ["unknown", 0],
		] as const satisfies ReadonlyArray<readonly [PaneTaskStatus, number]>) {
			await writeTaskRegistry(root, { own: { agent: "runtime", taskId: "own", task: "implement", kind: "pane", status } });
			await check(want);
		}
		// A registry read failure remains unknown, rather than claiming zero.
		for (const content of ["{", "null"]) {
			writeFileSync(taskRegistryPath(root), content);
			await check(null);
		}
		// The existing stats interface on an older producer has no count method.
		globals[STATS] = { list: () => [] };
		await check(null);
		delete globals[STATS];
		await check(0);
	} finally {
		if (prior === undefined) delete globals[STATS];
		else globals[STATS] = prior;
		teardown(harness);
		rmSync(project, { recursive: true, force: true });
	}
}

test("Stop carries this session's registered working agents and clears after completion", async () => {
	await assertPayloadCounts();
});

test("must-fail: a Stop payload without the task count fails the payload assertions", async () => {
	const root = initRustRepo("pi-hooks-no-working-count-");
	try {
		const carrier = (await import(mutatedCarrier(root, "no-count", "hooks.ts", "working_agents: workingAgents,", "/* working_agents: workingAgents, */"))).default;
		await expect(assertPayloadCounts(carrier)).rejects.toThrow();
	} finally { rmSync(root, { recursive: true, force: true }); }
});

for (const [name, file, before, after] of [
	["working task omitted", "index.ts", 'taskStatus(record.status).phase === "working").length;', 'false && taskStatus(record.status).phase === "working").length;'],
	["failed read reported empty", "tasks.ts", 'if (requireReadable && (error as NodeJS.ErrnoException).code !== "ENOENT") throw error;', 'if (false && requireReadable && (error as NodeJS.ErrnoException).code !== "ENOENT") throw error;'],
	["invalid registry reported empty", "tasks.ts", 'if (requireReadable && (!parsed || typeof parsed !== "object"))', 'if (false && requireReadable && (!parsed || typeof parsed !== "object"))'],
] as const) {
	test(`must-fail: ${name} fails the payload assertions`, async () => {
		const module = file === "index.ts"
			? await importRuntimeCopy(file, before, after)
			: await importRuntimeCopy("index.ts", '} from "./tasks.js";', `} from ${JSON.stringify(writeRuntimeCopy(file, before, after))};`);
		const extension = (module as typeof import("../../pi-agents-tmux/extensions/subagent/index.ts")).default;
		await expect(assertPayloadCounts(undefined, { extension })).rejects.toThrow();
	});
}
