import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { settingNumber } from "../extensions/subagent/settings.js";
import { MAX_CONCURRENCY } from "../extensions/subagent/types.js";

type ManifestSetting = {
	key: string;
	default?: unknown;
	description?: string;
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

test("legacy maxParallelTasks setting does not affect maxConcurrency", () => {
	const cwd = mkdtempSync(join(tmpdir(), "pi-agents-settings-"));
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
