// Lane assignment, the agent inventory guard and the idle-transition wait.

import assert from "node:assert/strict";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import { assignEphemeralSessionKeys, formatInventoryValidationError, validateAgentInventory } from "../extensions/subagent/dispatch.js";
import { ONESHOT_SESSION_PREFIX, resolveBgSession } from "../extensions/subagent/sessions.js";
import { waitForIdleTransition } from "../extensions/subagent/wait.js";
import test, { after } from "node:test";
import { cleanupTempRuntimes, tempRuntime, withPollutedEnv } from "./single-agent-fixture.js";

after(cleanupTempRuntimes);

test("oneshot default mints unique lane per call in clean and polluted env", () => {
	const cleanRuntime = tempRuntime();
	const first = resolveBgSession(cleanRuntime, "reviewer-test");
	const second = resolveBgSession(cleanRuntime, "reviewer-test");
	assert.equal(first.explicit, false);
	assert.equal(second.explicit, false);
	assert.match(first.key, new RegExp(`^${ONESHOT_SESSION_PREFIX}`));
	assert.match(second.key, new RegExp(`^${ONESHOT_SESSION_PREFIX}`));
	assert.notEqual(first.key, second.key);
	assert.notEqual(first.path, second.path);
	const forwardedOneShot = resolveBgSession(cleanRuntime, "reviewer-test", first.key);
	assert.equal(forwardedOneShot.explicit, false);
	assert.equal(forwardedOneShot.ephemeral, true);
	assert.equal(forwardedOneShot.key, first.key);

	withPollutedEnv(() => {
		const pollutedRuntime = tempRuntime();
		const pollutedFirst = resolveBgSession(pollutedRuntime, "reviewer-test");
		const pollutedSecond = resolveBgSession(pollutedRuntime, "reviewer-test");
		assert.notEqual(pollutedFirst.key, pollutedSecond.key);
		assert.match(pollutedFirst.key, new RegExp(`^${ONESHOT_SESSION_PREFIX}`));
	});
});

test("parallel tasks for same agent get distinct ephemeral lanes", () => {
	const tasks = assignEphemeralSessionKeys([
		{ agent: "reviewer-test", task: "one" },
		{ agent: "reviewer-test", task: "two" },
		{ agent: "reviewer-test", task: "three" },
	]);
	assert.equal(new Set(tasks.map((item) => item.sessionKey)).size, 3);
	for (const task of tasks) assert.match(task.sessionKey ?? "", new RegExp(`^${ONESHOT_SESSION_PREFIX}`));
});

test("explicit sessionKey reuses same lane", () => {
	const runtimeRoot = tempRuntime();
	const first = resolveBgSession(runtimeRoot, "reviewer-test", "issue-27");
	const second = resolveBgSession(runtimeRoot, "reviewer-test", "issue-27");
	assert.equal(first.explicit, true);
	assert.equal(first.ephemeral, false);
	assert.equal(first.key, "issue-27");
	assert.equal(second.key, "issue-27");
	assert.equal(first.path, second.path);
});

test("inventory guard rejects unknown agent with structured available lists", () => {
	const projectAgent: AgentConfig = { name: "planner", description: "plan", pane: true, systemPrompt: "", source: "project", filePath: "planner.md" };
	const userAgent: AgentConfig = { name: "personal", description: "user", pane: false, systemPrompt: "", source: "user", filePath: "personal.md" };
	const validation = validateAgentInventory(["missing"], { allowed: [projectAgent], project: [projectAgent], user: [userAgent] }, "project");
	assert.ok(validation);
	assert.deepEqual(validation?.missing, ["missing"]);
	assert.deepEqual(validation?.available.project, ["planner"]);
	assert.deepEqual(validation?.available.user, ["personal"]);
	assert.match(formatInventoryValidationError(validation!), /Unknown subagent\(s\).*missing/);
	assert.match(formatInventoryValidationError(validation!), /Project agents: planner/);
	assert.match(formatInventoryValidationError(validation!), /User agents: personal/);
});

test("wait_for_subagent_idle helper resolves on idle transition", async () => {
	const states = [{ isIdle: false }, { isIdle: false }, { isIdle: true }];
	const result = await waitForIdleTransition(async () => states.shift(), 1_000, 1);
	assert.equal(result.transitioned, true);
	assert.equal(result.timedOut, false);
	assert.equal(result.status, "idle-after-busy");
	assert.equal(result.samples, 3);
	assert.equal(result.lastState?.isIdle, true);
});

test("wait_for_subagent_idle distinguishes never-busy from idle-after-busy", async () => {
	const result = await waitForIdleTransition(async () => ({ isIdle: true }), 5, 1);
	assert.equal(result.transitioned, false);
	assert.equal(result.status, "never-busy");
	assert.equal(result.timedOut, true);
});
