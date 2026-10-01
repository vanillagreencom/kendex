import assert from "node:assert/strict";
import test, { after } from "node:test";
import * as runner from "../extensions/subagent/runner.js";
import * as dispatch from "../extensions/subagent/dispatch.js";
import { assertAbortNoRetry, assertFreshHandoff, assertNoEphemeralMetadata, assertSessionMetadata, bridgeEvent, bridgeStdout, cleanupTempRuntimes, dispatchOutcome, installMockSpawn, tempRuntime, writeSettings } from "./single-agent-fixture.js";
import { importRuntimeCopy, stripAnsi, theme } from "./browser-fixture.js";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { resolveBgSession } from "../extensions/subagent/sessions.js";
import { renderDashboardWidgetLines } from "../extensions/subagent/dashboard.js";

after(cleanupTempRuntimes);

test("context threshold hands the new task and prior final result to a fresh agent", () => assertFreshHandoff(runner));

for (const transport of ["long-report", "child-error"] as const) {
	test(`handoff prompt files survive ${transport} transport and are removed after child exit`, () => assertFreshHandoff(runner, transport));
}

test("control: inline long-report input reaches the real Linux process argument limit", { skip: process.platform !== "linux" }, async () => {
	const mutant = await importRuntimeCopy("runner.ts", 'args.push(`@${tmpTask.filePath}`);', 'args.push(`Task: ${task}`);') as typeof runner;
	await assert.rejects(() => assertFreshHandoff(mutant, "long-report"), error => (error instanceof assert.AssertionError && error.message.includes("E2BIG")) || (error as NodeJS.ErrnoException).code === "E2BIG");
});

test("control: transcript metadata retains the temporary user prompt reference", async () => {
	const mutant = await importRuntimeCopy("runner.ts", 'if (sanitized.at(-1)?.startsWith("@")) sanitized.pop();', 'if (false && sanitized.at(-1)?.startsWith("@")) sanitized.pop();') as typeof runner;
	await assert.rejects(() => assertFreshHandoff(mutant), assert.AssertionError);
});

for (const transport of ["mock", "child-error"] as const) {
	test(`control: prompt lifetime without cleanup retains files after ${transport}`, async () => {
		const mutant = await importRuntimeCopy("runner.ts", 'for (const dir of tmpPromptDirs) removePromptTempDir(dir);', 'for (const dir of tmpPromptDirs) void dir;') as typeof runner;
		await assert.rejects(() => assertFreshHandoff(mutant, transport), assert.AssertionError);
	});
}

for (const mode of ["single", "parallel", "chain"] as const) {
	test(`${mode} does not advertise internal keys for unguarded redispatch`, () => assertNoEphemeralMetadata(dispatch, mode));
	test(`control: ${mode} advertises an internal key that bypasses the reuse guard`, async () => {
		const mutant = await importRuntimeCopy("dispatch.ts", 'item.sessionKeyExplicit && item.sessionKey ?', 'item.sessionKey ?') as typeof dispatch;
		await assert.rejects(() => assertNoEphemeralMetadata(mutant, mode), assert.AssertionError);
	});
	test(`${mode} returns replacement and explicit session keys outside truncated answers`, async () => {
		for (const explicitSibling of [false, true]) await assertSessionMetadata(dispatch, mode, "completed", explicitSibling);
	});
	test(`control: ${mode} omits model-facing session metadata`, async () => {
		const mutant = await importRuntimeCopy("dispatch.ts", `return withPaneFallbackNotice(await ${mode}Dispatch(flow, lane), lane, flow.agents);`, `return ${mode}Dispatch(flow, lane);`) as typeof dispatch;
		await assert.rejects(() => assertSessionMetadata(mutant, mode), assert.AssertionError);
	});
}

for (const ending of ["failed", "needs_completion"] as const) {
	test(`chain retains explicit executed session keys before ${ending}`, async () => {
		for (const explicitSibling of [false, true]) await assertSessionMetadata(dispatch, "chain", ending, explicitSibling);
	});
	test(`control: early ${ending} drops an earlier handoff key`, async () => {
		const mutant = await importRuntimeCopy("dispatch.ts", 'result.details.results.flatMap((item, index)', 'result.details.results.slice(-1).flatMap((item, index)') as typeof dispatch;
		await assert.rejects(() => assertSessionMetadata(mutant, "chain", ending), assert.AssertionError);
	});
}

test("fresh handoff reaches the tool result and compact panel", async () => {
	const root = tempRuntime();
	const cwd = tempRuntime();
	writeSettings(cwd, { reusedSessionContextLimitTokens: 100, reusedSessionBudgetThreshold: 0.8 });
	const session = resolveBgSession(root, "reviewer-test", "reuse");
	mkdirSync(join(root, "sessions"), { recursive: true });
	writeFileSync(session.path, `${JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "prior result" }] } })}\n`.padEnd(432, " "));
	installMockSpawn([{ stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "fresh answer" }] } })]) }]);
	try {
		const { result, row } = await dispatchOutcome({ cwd, runtimeRoot: root, sessionKey: "reuse" });
		const notice = "reused as fresh (context 108%)";
		const state = { items: { task: row }, visible: true, collapsed: false, mode: "compact" as const };
		assert.deepEqual([result.content[0]?.text.includes(notice), row.reuseNotice, stripAnsi(renderDashboardWidgetLines(state, theme, cwd, 180).join("\n")).includes(notice)], [true, notice, true]);
		const mutant = await importRuntimeCopy("dashboard.ts", 'item.status === "completed" && !item.reuseNotice', 'item.status === "completed"') as typeof import("../extensions/subagent/dashboard.js");
		assert.throws(() => assert.ok(stripAnsi(mutant.renderDashboardWidgetLines(state, theme, cwd, 180).join("\n")).includes(notice)), assert.AssertionError);
	} finally { runner.setSingleAgentSpawnForTests(); }
});

test("parent cancellation does not retry a recorded overflow", () => assertAbortNoRetry(runner));

test("control: checking only overflow retries after parent cancellation", async () => {
	const mutant = await importRuntimeCopy("runner.ts", 'first.stopReason === "aborted" || !resultHasContextLengthExceeded(first)', 'false && first.stopReason === "aborted" || !resultHasContextLengthExceeded(first)') as typeof runner;
	await assert.rejects(() => assertAbortNoRetry(mutant), assert.AssertionError);
});

test("control: refusing ordinary over-threshold reuse prevents the fresh-agent handoff", async () => {
	const mutant = await importRuntimeCopy("runner.ts",
		"if (budgetGuard && !budgetGuard.ok && !sameSession) {", "if (false && budgetGuard && !budgetGuard.ok && !sameSession) {",
		[{ before: "if (budgetGuard && !budgetGuard.ok && sameSession) {", after: "if (budgetGuard && !budgetGuard.ok) {" }],
	) as typeof runner;
	await assert.rejects(() => assertFreshHandoff(mutant), assert.AssertionError);
});

for (const omitted of ["task", "prior-result"] as const) test(`control: handoff drops ${omitted}`, async () => {
	const mutant = await importRuntimeCopy("sessions.ts",
		'task: `${task}\\n\\nPrior agent final result (${estimate.path}):\\n${priorResult ?? "No prior final result available."}`',
		omitted === "task" ? 'task: `Prior agent final result (${estimate.path}):\\n${priorResult ?? "No prior final result available."}`' : 'task: `${task}\\n\\nPrior agent final result (${estimate.path}):\\nNo prior final result available.`',
	) as typeof import("../extensions/subagent/sessions.js");
	const key = Symbol.for("test.context-handoff");
	const globals = globalThis as unknown as Record<symbol, unknown>;
	globals[key] = mutant.prepareContextHandoff;
	// Inject only the real handoff owner; spawning and the guard stay real.
	const copy = await importRuntimeCopy("runner.ts", '\tprepareContextHandoff,', '', [
		{ before: 'import { createTaskId, emitSubagentEvent, tryEmitSubagentEvent }', after: `const prepareContextHandoff = globalThis[Symbol.for("test.context-handoff")];\nimport { createTaskId, emitSubagentEvent, tryEmitSubagentEvent }` },
	]) as typeof runner;
	try { await assert.rejects(() => assertFreshHandoff(copy), assert.AssertionError); }
	finally { delete globals[key]; }
});
