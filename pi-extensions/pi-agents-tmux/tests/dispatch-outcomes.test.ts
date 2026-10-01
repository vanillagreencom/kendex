import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import test, { after } from "node:test";
import * as dispatch from "../extensions/subagent/dispatch.js";
import { setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { resolveBgSession } from "../extensions/subagent/sessions.js";
import { renderDashboardWidgetLines } from "../extensions/subagent/dashboard.js";
import { subagentToolRenderers } from "../extensions/subagent/subagent-render.js";
import { assertDispatchOutcome, bridgeEvent, bridgeStdout, cleanupTempRuntimes, dispatchOutcome, installMockSpawn, tempRuntime, writeSettings } from "./single-agent-fixture.js";
import { importRuntimeCopy, stripAnsi, theme } from "./browser-fixture.js";

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
		const { result, row } = await assertDispatchOutcome("refused", { cwd, runtimeRoot: root, sessionKey: "reuse", sameSession: true }, "108/100 tokens (108%) exceeds 80% guard threshold");
		assert.deepEqual([calls.length, row.message?.includes("Start a fresh agent"), result.content[0]?.text.includes("Start a fresh agent")], [0, true, true]);
		assert.equal(readFileSync(session.path, "utf8").length, 432);
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
	const mutant = await importRuntimeCopy("dispatch.ts", '\tif (status === "refused" || status === "failed" || status === "stopped") return result.errorMessage || result.stderr || getFinalOutput(result.messages) || COMPLETION_SUMMARY_UNAVAILABLE;', '\tif (false) return result.errorMessage || result.stderr || getFinalOutput(result.messages) || COMPLETION_SUMMARY_UNAVAILABLE;') as typeof dispatch;
	installMockSpawn([{ code: 1, stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [], stopReason: "error", errorMessage: providerRows[0] } })]) }]);
	try { await assert.rejects(() => assertDispatchOutcome("failed", { run: mutant.runSingleDispatch }, providerRows[0]!), assert.AssertionError); }
	finally { setSingleAgentSpawnForTests(); }
});

test("control: the old panel row omits the provider message", async () => {
	const condition = 'item.status === "failed" || item.status === "refused" || item.status === "stopped" || item.reuseNotice';
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
