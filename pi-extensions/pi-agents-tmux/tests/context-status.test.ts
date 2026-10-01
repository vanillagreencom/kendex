import assert from "node:assert/strict";
import test, { after } from "node:test";
import { assertAgentContextBudget } from "./extension-fixture.js";
import { assertBudgetMigration, cleanupTempRuntimes, tempRuntime } from "./single-agent-fixture.js";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { guardReusedSessionBudget } from "../extensions/subagent/sessions.js";
import { importRuntimeCopy } from "./browser-fixture.js";

after(cleanupTempRuntimes);

for (const route of ["background", "pane"] as const) {
	test(`stored-ID reuse reads the target guard estimate and model: ${route}`, () => assertAgentContextBudget(undefined, route));
}

for (const policy of ["refuse-and-warn", "warn", "compact-then-resume"]) {
	test(`legacy policy ${policy} is read with a migration warning`, () => assertBudgetMigration(guardReusedSessionBudget, policy));
}

test("control: ignoring the former setting loses the migration warning", async () => {
	const mutant = await importRuntimeCopy("sessions.ts", 'const migrationWarning = legacyPolicy ?', 'const migrationWarning = false && legacyPolicy ?') as typeof import("../extensions/subagent/sessions.js");
	await assert.rejects(() => assertBudgetMigration(mutant.guardReusedSessionBudget, "warn"), assert.AssertionError);
});

test("control: permitting an exhausted session defeats the guard threshold", async () => {
	const mutant = await importRuntimeCopy("sessions.ts", '!estimate.exists || estimate.ratio <= estimate.threshold', 'true || !estimate.exists || estimate.ratio <= estimate.threshold') as typeof import("../extensions/subagent/sessions.js");
	const cwd = tempRuntime();
	const file = join(cwd, "session.jsonl");
	writeFileSync(file, " ".repeat(870_401));
	const budget = await mutant.guardReusedSessionBudget(file, "scout", undefined, cwd);
	assert.throws(() => assert.equal(budget.ok, false), assert.AssertionError);
});

test("a context read failure is not an empty saved session", async () => {
	const sessions = await import("../extensions/subagent/sessions.js");
	const cwd = tempRuntime();
	const parent = join(cwd, "file");
	writeFileSync(parent, "not a directory");
	await assert.rejects(() => sessions.estimateSessionBudget(join(parent, "session.jsonl"), undefined, cwd), { code: "ENOTDIR" });
	const mutant = await importRuntimeCopy("sessions.ts", 'if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;', 'if ((error as NodeJS.ErrnoException).code !== "ENOENT") { void error; }') as typeof sessions;
	await assert.rejects(async () => {
		await assert.rejects(() => mutant.estimateSessionBudget(join(parent, "session.jsonl"), undefined, cwd), { code: "ENOTDIR" });
	}, assert.AssertionError);
});

test("control: the old result lookup supplies no background context figure", async () => {
	const tools = await importRuntimeCopy("pane-support-tools.ts", 'if (params.sessionKey) {', 'if (false && params.sessionKey) {') as typeof import("../extensions/subagent/pane-support-tools.js");
	const key = Symbol.for("test.context-status");
	const globals = globalThis as unknown as Record<symbol, unknown>;
	globals[key] = tools.registerPaneSupportTools;
	try {
		const extension = await importRuntimeCopy("index.ts", 'import { registerPaneSupportTools } from "./pane-support-tools.js";', 'const registerPaneSupportTools = globalThis[Symbol.for("test.context-status")];') as typeof import("../extensions/subagent/index.js");
		await assert.rejects(() => assertAgentContextBudget(extension.default), assert.AssertionError);
	} finally { delete globals[key]; }
});

for (const defect of ["pane-report", "background-cwd", "pane-cwd", "background-model"] as const) {
	test(`control: context lookup loses ${defect}`, async () => {
		const edits = {
			"pane-report": ['const contextBudget = finalRecord.transcriptPath ?', 'const contextBudget = false && finalRecord.transcriptPath ?'],
			"background-cwd": ['params.agent, model, params.cwd ?? ctx.cwd)', 'params.agent, model, ctx.cwd)'],
			"pane-cwd": ['pane?.cwd ?? params.cwd ?? ctx.cwd)', 'ctx.cwd)'],
			"background-model": ['const model = selectedModelForAgent(agent, parentModel, ctx.cwd);', 'const model = undefined;'],
		} as const;
		const [before, after] = edits[defect];
		const tools = await importRuntimeCopy("pane-support-tools.ts", before, after) as typeof import("../extensions/subagent/pane-support-tools.js");
		const key = Symbol.for("test.context-status");
		const globals = globalThis as unknown as Record<symbol, unknown>;
		globals[key] = tools.registerPaneSupportTools;
		try {
			const extension = await importRuntimeCopy("index.ts", 'import { registerPaneSupportTools } from "./pane-support-tools.js";', 'const registerPaneSupportTools = globalThis[Symbol.for("test.context-status")];') as typeof import("../extensions/subagent/index.js");
			await assert.rejects(() => assertAgentContextBudget(extension.default, defect.startsWith("pane") ? "pane" : "background"), assert.AssertionError);
		} finally { delete globals[key]; }
	});
}
