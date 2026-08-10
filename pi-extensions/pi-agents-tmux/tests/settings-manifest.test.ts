import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after } from "node:test";
import { bgTaskTimeoutMs, DEFAULT_BG_TASK_TIMEOUT_MS, recordProjectTrust, settingNumber } from "../extensions/subagent/settings.js";
import { DEFAULT_MODEL_CONTEXT_LIMIT_TOKENS } from "../extensions/subagent/sessions.js";
import { DEFAULT_RESULT_MAX_BYTES, DEFAULT_RESULT_MAX_LINES, MAX_CONCURRENCY } from "../extensions/subagent/types.js";

const tempDirs: string[] = [];

after(() => {
	for (const dir of tempDirs) rmSync(dir, { force: true, recursive: true });
});

type ManifestSetting = {
	apply?: string;
	category?: string;
	key: string;
	default?: unknown;
	description?: string;
	type?: string;
};

function manifestSettings(): ManifestSetting[] {
	const manifest = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
	return manifest.vstack.extensionManager.settings as ManifestSetting[];
}

function writeProjectSettings(cwd: string, config: Record<string, unknown>): void {
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({
		vstack: { extensionManager: { config: { "@vanillagreen/pi-agents-tmux": config } } },
	}), "utf8");
	recordProjectTrust({ cwd, isProjectTrusted: () => true });
}

test("settings metadata hides deprecated maxParallelTasks", () => {
	const keys = manifestSettings().map((item) => item.key);
	assert.ok(!keys.includes("maxParallelTasks"));
});

test("settings metadata keeps maxConcurrency visible and scoped", () => {
	const maxConcurrency = manifestSettings().find((item) => item.key === "maxConcurrency");
	assert.ok(maxConcurrency, "maxConcurrency setting remains visible");
	assert.equal(maxConcurrency.default, MAX_CONCURRENCY);
	assert.match(maxConcurrency.description ?? "", /one-shot\/background agent executions/i);
	assert.match(maxConcurrency.description ?? "", /parallel dispatch queue/i);
	assert.match(maxConcurrency.description ?? "", /Persistent pane agents occupy a worker only until launch\/enqueue/i);
});

test("settings metadata keeps bgTaskTimeoutMs visible and disableable", () => {
	const bgTimeout = manifestSettings().find((item) => item.key === "bgTaskTimeoutMs");
	assert.ok(bgTimeout, "bgTaskTimeoutMs setting remains visible");
	assert.equal(bgTimeout.default, DEFAULT_BG_TASK_TIMEOUT_MS);
	assert.equal(bgTimeout.type, "number");
	assert.equal(bgTimeout.category, "Execution");
	assert.equal(bgTimeout.apply, "live");
	assert.match(bgTimeout.description ?? "", /marked unresponsive/i);
	assert.match(bgTimeout.description ?? "", /0 to disable/i);

	const cwd = mkdtempSync(join(tmpdir(), "pi-agents-bg-timeout-"));
	tempDirs.push(cwd);
	writeProjectSettings(cwd, { bgTaskTimeoutMs: 0 });
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(cwd, "agent");
	try {
		assert.equal(bgTaskTimeoutMs(cwd), 0);
	} finally {
		if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousPiDir;
	}
});

test("settings metadata keeps reused session context limit aligned with runtime default", () => {
	const limit = manifestSettings().find((item) => item.key === "reusedSessionContextLimitTokens");
	assert.ok(limit, "reusedSessionContextLimitTokens setting remains visible");
	assert.equal(limit.default, DEFAULT_MODEL_CONTEXT_LIMIT_TOKENS);
	assert.equal(limit.type, "number");
	assert.equal(limit.category, "Execution");
	assert.equal(limit.apply, "live");
});

test("settings metadata keeps artifact-first result caps aligned with runtime defaults", () => {
	const maxBytes = manifestSettings().find((item) => item.key === "resultMaxBytes");
	assert.ok(maxBytes, "resultMaxBytes setting remains visible");
	assert.equal(maxBytes.default, DEFAULT_RESULT_MAX_BYTES);
	assert.equal(maxBytes.type, "number");
	assert.equal(maxBytes.category, "Output");
	assert.equal(maxBytes.apply, "live");
	assert.match(maxBytes.description ?? "", /base inline byte budget/i);
	assert.match(maxBytes.description ?? "", /parallel dispatch divides/i);
	assert.match(maxBytes.description ?? "", /preserveFullOutput/i);

	const maxLines = manifestSettings().find((item) => item.key === "resultMaxLines");
	assert.ok(maxLines, "resultMaxLines setting remains visible");
	assert.equal(maxLines.default, DEFAULT_RESULT_MAX_LINES);
	assert.equal(maxLines.type, "number");
	assert.equal(maxLines.category, "Output");
	assert.equal(maxLines.apply, "live");
	assert.match(maxLines.description ?? "", /base inline line budget/i);
	assert.match(maxLines.description ?? "", /parallel dispatch divides/i);
	assert.match(maxLines.description ?? "", /preserveFullOutput/i);
});

test("legacy maxParallelTasks setting does not affect maxConcurrency", () => {
	const cwd = mkdtempSync(join(tmpdir(), "pi-agents-settings-"));
	tempDirs.push(cwd);
	writeProjectSettings(cwd, { maxParallelTasks: 1 });
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(cwd, "agent");
	try {
		assert.equal(settingNumber("maxConcurrency", MAX_CONCURRENCY, cwd), MAX_CONCURRENCY);
	} finally {
		if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousPiDir;
	}
});
