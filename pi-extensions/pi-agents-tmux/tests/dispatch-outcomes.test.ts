import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import test, { after } from "node:test";
import { spyOn } from "bun:test";
import * as runner from "../extensions/subagent/runner.js";
import { assertRegisteredExactSession } from "./extension-fixture.js";
import * as dispatch from "../extensions/subagent/dispatch.js";
import { setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { resolveBgSession } from "../extensions/subagent/sessions.js";
import { renderDashboardWidgetLines } from "../extensions/subagent/dashboard.js";
import { subagentToolRenderers } from "../extensions/subagent/subagent-render.js";
import { assertProviderProducer, assertDispatchOutcome, bridgeEvent, bridgeStdout, cleanupTempRuntimes, dispatchOutcome, installMockSpawn, tempRuntime, writeSettings } from "./single-agent-fixture.js";
import { importRuntimeCopy, stripAnsi, theme, toneTheme } from "./browser-fixture.js";
import { monitorStatusIcon, monitorStatusText, buildMonitorSessionGroups } from "../extensions/subagent/browser/monitor-tree.js";
import { mergeLiveDashboardItems } from "../extensions/subagent/task-records.js";
import { ICONS } from "../extensions/subagent/types.js";

after(cleanupTempRuntimes);

const providerRows = [
	"github-copilot API error (403): 403 forbidden",
	"API error (429): rate limit exceeded",
	"quota exhausted",
];

// A Pi assistant message can report an error even when print mode exits zero.
for (const diagnostic of providerRows) {
	test(`provider outcome retains ${diagnostic}`, async () => {
		const calls = installMockSpawn([{ stdout: bridgeStdout([
			bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "progress before error" }], stopReason: "error", errorMessage: diagnostic } }),
		]) }]);
		try {
			const { result, row } = await assertDispatchOutcome("failed", {}, diagnostic);
			assert.equal(calls.length, 1, "provider failures gain no retry policy");
			const panel = stripAnsi(renderDashboardWidgetLines({ items: { task: row }, mode: "normal", collapsed: false, visible: true }, theme, tempRuntime(), 220).join("\n"));
			assert.ok(panel.includes(diagnostic));
			assert.ok(panel.includes("failed"));
			for (const mode of ["single", "parallel", "chain"] as const) {
				const tool = stripAnsi(subagentToolRenderers.renderResult({ ...result, details: { ...result.details, mode } }, { expanded: false }, theme, { cwd: tempRuntime() }).render(220).join("\n"));
				assert.deepEqual([tool.includes(diagnostic), tool.includes("failed")], [true, true], mode);
			}
		} finally { setSingleAgentSpawnForTests(); }
	});
}

test("exact-session context refusal carries the guard text and fresh-agent remedy", async () => {
	const cwd = tempRuntime();
	const root = tempRuntime();
	writeSettings(cwd, { reusedSessionContextLimitTokens: 100, reusedSessionBudgetThreshold: 0.8 });
	const session = resolveBgSession(root, "reviewer-test", "reuse");
	mkdirSync(dirname(session.path), { recursive: true });
	writeFileSync(session.path, "x".repeat(432));
	const calls = installMockSpawn([]);
	try {
		const { result, row, events } = await assertDispatchOutcome("refused", { cwd, runtimeRoot: root, sessionKey: "reuse", sameSession: true }, "108/100 tokens (108%) exceeds 80% guard threshold");
		assert.deepEqual([calls.length, row.message?.includes("Start a fresh agent"), result.content[0]?.text.includes("Start a fresh agent")], [0, true, true]);
		assert.equal(readFileSync(session.path, "utf8").length, 432);
		assert.deepEqual(events, [], "pre-dispatch refusal remains event-free");
		const monitorRecord = Object.values(mergeLiveDashboardItems({}, [row]))[0]!;
		assert.deepEqual([monitorStatusIcon(monitorRecord.status, toneTheme as any, false), monitorStatusText(monitorRecord.status, toneTheme as any), buildMonitorSessionGroups([monitorRecord])[0]!.isActive], [`<warning>${ICONS.warning}</warning>`, "<warning>refused</warning>", false]);
		const mutant = await importRuntimeCopy("browser/monitor-tree.ts", 'return dashboardStatusIcon(status, theme, { animateSpinners });', 'return theme.fg("muted", "·");') as typeof import("../extensions/subagent/browser/monitor-tree.js");
		assert.throws(() => assert.equal(mutant.monitorStatusIcon(monitorRecord.status, toneTheme as any), `<warning>${ICONS.warning}</warning>`), assert.AssertionError);
		const panel = stripAnsi(renderDashboardWidgetLines({ items: { task: row }, mode: "compact", collapsed: false, visible: true }, theme, cwd, 160).join("\n"));
		assert.ok(panel.includes("refused") && panel.includes("108/100") && panel.includes("80%") && panel.includes("Start a fresh agent"));
		assert.ok(!panel.includes("failed"));
	} finally { setSingleAgentSpawnForTests(); }
});

test("parent abort is stopped in the panel and tool result", async () => {
	const controller = new AbortController();
	controller.abort();
	installMockSpawn([{ stdout: bridgeStdout([bridgeEvent("agent_end", { content: [] })]) }]);
	try {
		const { result, row } = await assertDispatchOutcome("stopped", { signal: controller.signal }, "Agent was aborted");
		const tool = stripAnsi(subagentToolRenderers.renderResult(result, { expanded: false }, theme, {}).render(200).join("\n"));
		assert.ok(tool.includes("stopped"));
		assert.ok(!tool.includes("failed"));
		assert.equal(row.status, "stopped");
		const monitorRecord = Object.values(mergeLiveDashboardItems({}, [row]))[0]!;
		assert.deepEqual([monitorStatusIcon(monitorRecord.status, toneTheme as any, false), monitorStatusText(monitorRecord.status, toneTheme as any), buildMonitorSessionGroups([monitorRecord])[0]!.isActive], [`<warning>${ICONS.warning}</warning>`, "<warning>stopped</warning>", false]);
	} finally { setSingleAgentSpawnForTests(); }
});

// Restore the exit-code-only decision. Each original misclassification must turn its own assertion red.
const exitOnly = `function singleResultStatus(result) {
	if (result.status === "needs_completion") return "needs_completion";
	if (result.exitCode === -1) return "running";
	if (result.exitCode === 0) return "completed";
	return "failed";
}
function singleResultIsError(result) {
	return singleResultStatus(result) === "failed" || result.stopReason === "error" || result.stopReason === "aborted";
}`;

for (const status of ["refused", "stopped", "failed"] as const) {
	test(`control: exit-code-only decision misclassifies ${status}`, async () => {
		const mutant = await importRuntimeCopy("dispatch.ts", 'import { singleResultIsError, singleResultStatus } from "./outcomes.js";', exitOnly) as typeof dispatch;
		const root = tempRuntime();
		const cwd = tempRuntime();
		writeSettings(cwd, { reusedSessionContextLimitTokens: 100 });
		const session = resolveBgSession(root, "reviewer-test", "reuse");
		mkdirSync(dirname(session.path), { recursive: true });
		writeFileSync(session.path, "x".repeat(432));
		const controller = new AbortController();
		if (status === "stopped") controller.abort();
		const diagnostic = status === "failed" ? providerRows[0]! : status === "stopped" ? "Agent was aborted" : "108/100";
		installMockSpawn([{ stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [], stopReason: "error", errorMessage: providerRows[0] } })]) }]);
		try {
			await assert.rejects(() => assertDispatchOutcome(status, { run: mutant.runSingleDispatch, cwd, runtimeRoot: root, sessionKey: status === "refused" ? "reuse" : undefined, sameSession: true, signal: controller.signal }, diagnostic), assert.AssertionError);
		} finally { setSingleAgentSpawnForTests(); }
	});
}

test("control: terminal dashboard placeholder loses the provider reason", async () => {
	const mutant = await importRuntimeCopy("dispatch.ts", '\tif (singleResultIsError(result)) return result.errorMessage || result.stderr || getFinalOutput(result.messages) || COMPLETION_SUMMARY_UNAVAILABLE;', '\tif (false) return result.errorMessage || result.stderr || getFinalOutput(result.messages) || COMPLETION_SUMMARY_UNAVAILABLE;') as typeof dispatch;
	installMockSpawn([{ code: 1, stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [], stopReason: "error", errorMessage: providerRows[0] } })]) }]);
	try { await assert.rejects(() => assertDispatchOutcome("failed", { run: mutant.runSingleDispatch }, providerRows[0]!), assert.AssertionError); }
	finally { setSingleAgentSpawnForTests(); }
});

test("control: the old panel row omits the provider message", async () => {
	const condition = 'taskStatus(item.status).diagnostic || item.reuseNotice';
	const mutant = await importRuntimeCopy("dashboard.ts", `if (${condition}) {`, `if (false && (${condition})) {`) as typeof import("../extensions/subagent/dashboard.js");
	installMockSpawn([{ stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [], stopReason: "error", errorMessage: providerRows[0] } })]) }]);
	try {
		const { row } = await dispatchOutcome();
		const panel = stripAnsi(mutant.renderDashboardWidgetLines({ items: { task: row }, mode: "normal", collapsed: false, visible: true }, theme, tempRuntime(), 220).join("\n"));
		assert.throws(() => assert.ok(panel.includes(providerRows[0]!)), assert.AssertionError);
	} finally { setSingleAgentSpawnForTests(); }
});

test("control: exit-code-only tool rendering calls provider errors completed", async () => {
	const mutant = await importRuntimeCopy("subagent-render.ts", 'import { singleResultIsError, singleResultStatus } from "./outcomes.js";', exitOnly) as typeof import("../extensions/subagent/subagent-render.js");
	installMockSpawn([{ stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [], stopReason: "error", errorMessage: providerRows[0] } })]) }]);
	try {
		const { result } = await dispatchOutcome();
		const rendered = stripAnsi(mutant.subagentToolRenderers.renderResult(result, { expanded: false }, theme, {}).render(220).join("\n"));
		assert.throws(() => assert.ok(rendered.includes("failed")), assert.AssertionError);
	} finally { setSingleAgentSpawnForTests(); }
});

const sessionRows = [
	{ name: "single", params: { agent: "scout", task: "map", sessionKey: "reuse", sameSession: true } },
	{ name: "parallel/top", params: { tasks: [{ agent: "scout", task: "map", sessionKey: "reuse" }], sameSession: true } },
	{ name: "chain/top", params: { chain: [{ agent: "scout", task: "map", sessionKey: "reuse" }], sameSession: true } },
	{ name: "parallel/item", params: { tasks: [{ agent: "scout", task: "map", sessionKey: "reuse", sameSession: true }] } },
	{ name: "chain/item", params: { chain: [{ agent: "scout", task: "map", sessionKey: "reuse", sameSession: true }] } },
];

for (const overflow of ["guard", "provider"] as const) {
	for (const { name, params } of sessionRows) {
		test(`registered exact session survives ${overflow} overflow: ${name}`, () => assertRegisteredExactSession(params, overflow));
	}
}

for (const { name, params } of sessionRows.slice(0, 3)) {
	test(`control: public dispatch drops sameSession: ${name}`, async () => {
		const following = name === "single" ? "signal," : name.startsWith("parallel") ? "updateDashboard," : "cwd: ctx.cwd,";
		const mutant = await importRuntimeCopy("index.ts", `sameSession: params.sameSession,\n\t\t\t\t\t${following}`, `sameSession: undefined,\n\t\t\t\t\t${following}`) as typeof import("../extensions/subagent/index.js");
		await assert.rejects(() => assertRegisteredExactSession(params, "guard", mutant.default), assert.AssertionError);
	});
}

for (const { name, params } of sessionRows.slice(3)) {
	test(`control: dispatch drops per-item sameSession: ${name}`, async () => {
		const item = name.startsWith("parallel") ? "t" : "step";
		const dispatcher = name.startsWith("parallel") ? "runParallelDispatch" : "runChainDispatch";
		const mutant = await importRuntimeCopy("dispatch.ts", `${item}.sameSession ?? flow.sameSession`, 'flow.sameSession') as typeof dispatch;
		const key = Symbol.for("test.session-dispatch");
		const globals = globalThis as unknown as Record<symbol, unknown>;
		globals[key] = mutant[dispatcher];
		try {
			const extension = await importRuntimeCopy("index.ts", `\t${dispatcher},`, '', [{ before: 'function bridgeTargetArgs(', after: `const ${dispatcher} = globalThis[Symbol.for("test.session-dispatch")];\nfunction bridgeTargetArgs(` }]) as typeof import("../extensions/subagent/index.js");
			await assert.rejects(() => assertRegisteredExactSession(params, "guard", extension.default), assert.AssertionError);
		} finally { delete globals[key]; }
	});
}

test("control: provider overflow retries an exact session as fresh", async () => {
	const mutant = await importRuntimeCopy("runner.ts", '\tif (sameSession) {', '\tif (false && sameSession) {') as typeof runner;
	const key = Symbol.for("test.session-runner");
	const globals = globalThis as unknown as Record<symbol, unknown>;
	globals[key] = mutant.runSingleAgent;
	try {
		const dispatcher = await importRuntimeCopy("dispatch.ts", '\trunSingleAgent,', '', [{ before: 'import { createOneShotSessionKey }', after: 'const runSingleAgent = globalThis[Symbol.for("test.session-runner")];\nimport { createOneShotSessionKey }' }]) as typeof dispatch;
		globals[key] = dispatcher.runSingleDispatch;
		const extension = await importRuntimeCopy("index.ts", '\trunSingleDispatch,', '', [{ before: 'function bridgeTargetArgs(', after: 'const runSingleDispatch = globalThis[Symbol.for("test.session-runner")];\nfunction bridgeTargetArgs(' }]) as typeof import("../extensions/subagent/index.js");
		// The runner copy owns its spawn mock, so install it while the public fixture runs.
		const install = spyOn(runner, "setSingleAgentSpawnForTests").mockImplementation(mutant.setSingleAgentSpawnForTests);
		try { await assert.rejects(() => assertRegisteredExactSession(sessionRows[0]!.params, "provider", extension.default), assert.AssertionError); }
		finally { install.mockRestore(); }
	} finally { delete globals[key]; }
});

test("provider producer and saved output share the outcome judge", () => assertProviderProducer(runner));

for (const surface of ["producer", "saved-output"] as const) {
	test(`control: shared judge is bypassed in ${surface}`, async () => {
		const mutant = surface === "producer"
			? await importRuntimeCopy("runner.ts", 'import { singleResultIsError, singleResultStatus } from "./outcomes.js";', exitOnly)
			: await importRuntimeCopy("runner.ts", 'const isError = singleResultIsError(result);', 'const isError = false && singleResultIsError(result);');
		await assert.rejects(() => assertProviderProducer(mutant as typeof runner), assert.AssertionError);
	});
}
