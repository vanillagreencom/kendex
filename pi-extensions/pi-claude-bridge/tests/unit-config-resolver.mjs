/**
 * Tests for the external-config resolver the vstack extension manager calls to
 * display the value claude-bridge actually resolves from claude-bridge.json.
 */
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { loadConfig, recordProjectTrust, resolveExternalConfigValue } from "../src/config.ts";

function withTempDirs(fn) {
	const root = mkdtempSync(join(tmpdir(), "claude-bridge-resolver-"));
	const oldPiDir = process.env.PI_CODING_AGENT_DIR;
	const oldIsolated = process.env.CLAUDE_BRIDGE_ISOLATED;
	const oldHome = process.env.HOME;
	try {
		const user = join(root, "user");
		const project = join(root, "project");
		mkdirSync(user, { recursive: true });
		mkdirSync(join(project, ".pi"), { recursive: true });
		process.env.PI_CODING_AGENT_DIR = user;
		delete process.env.CLAUDE_BRIDGE_ISOLATED;
		return fn({ root, user, project });
	} finally {
		if (oldPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = oldPiDir;
		if (oldIsolated === undefined) delete process.env.CLAUDE_BRIDGE_ISOLATED;
		else process.env.CLAUDE_BRIDGE_ISOLATED = oldIsolated;
		if (oldHome === undefined) delete process.env.HOME;
		else process.env.HOME = oldHome;
		rmSync(root, { recursive: true, force: true });
	}
}

describe("resolveExternalConfigValue", () => {
	it("reports no value when no legacy config file exists", () => withTempDirs(({ project }) => {
		assert.deepEqual(resolveExternalConfigValue("enabled", project), { explicit: false, value: undefined });
		assert.deepEqual(resolveExternalConfigValue("fastMode", project), { explicit: false, value: undefined });
	}));

	it("reports a global legacy value with the file that supplied it", () => withTempDirs(({ user, project }) => {
		writeFileSync(join(user, "claude-bridge.json"), JSON.stringify({ enabled: false }));

		const resolved = resolveExternalConfigValue("enabled", project);
		assert.equal(resolved.explicit, true);
		assert.equal(resolved.value, false);
		assert.equal(resolved.source, join(user, "claude-bridge.json"));
		// The bug this closes: the modal must not render the manifest default.
		assert.equal(loadConfig(project).enabled, false);
	}));

	it("shows the global source as a home-relative path", () => withTempDirs(({ root, user, project }) => {
		process.env.HOME = root;
		writeFileSync(join(user, "claude-bridge.json"), JSON.stringify({ enabled: false }));

		assert.equal(resolveExternalConfigValue("enabled", project).source, "~/user/claude-bridge.json");
	}));

	it("lets a trusted project legacy file override the global one", () => withTempDirs(({ user, project }) => {
		writeFileSync(join(user, "claude-bridge.json"), JSON.stringify({ enabled: false, provider: { fastMode: false } }));
		writeFileSync(join(project, ".pi", "claude-bridge.json"), JSON.stringify({ enabled: true, provider: { fastMode: true } }));
		recordProjectTrust({ cwd: project, isProjectTrusted: () => true });

		const enabled = resolveExternalConfigValue("enabled", project);
		assert.equal(enabled.value, true);
		assert.equal(enabled.source, join(project, ".pi", "claude-bridge.json"));

		const fastMode = resolveExternalConfigValue("fastMode", project);
		assert.equal(fastMode.value, true);
		assert.equal(fastMode.source, join(project, ".pi", "claude-bridge.json"));

		// A key only the global file sets still reports the global file.
		writeFileSync(join(user, "claude-bridge.json"), JSON.stringify({ provider: { strictMcpConfig: false } }));
		const strict = resolveExternalConfigValue("strictMcpConfig", project);
		assert.equal(strict.value, false);
		assert.equal(strict.source, join(user, "claude-bridge.json"));
	}));

	it("resolves the nested legacy provider and promptContext shapes", () => withTempDirs(({ user, project }) => {
		writeFileSync(join(user, "claude-bridge.json"), JSON.stringify({
			promptContext: { includeAppendSystemPromptMd: true },
			provider: {
				enableConnectors: true,
				forceEffort: "max",
				modelEffortOverrides: { "claude-opus-4-8": "max" },
				pathToClaudeCodeExecutable: "/opt/claude/bin/claude",
			},
		}));

		assert.equal(resolveExternalConfigValue("enableConnectors", project).value, true);
		assert.equal(resolveExternalConfigValue("forceEffort", project).value, "max");
		assert.deepEqual(resolveExternalConfigValue("modelEffortOverrides", project).value, { "claude-opus-4-8": "max" });
		assert.equal(resolveExternalConfigValue("pathToClaudeCodeExecutable", project).value, "/opt/claude/bin/claude");
		assert.equal(resolveExternalConfigValue("includeAppendSystemPromptMd", project).value, true);
	}));

	it("resolves the flat manifest key shape the same way loadConfig does", () => withTempDirs(({ user, project }) => {
		writeFileSync(join(user, "claude-bridge.json"), JSON.stringify({
			fastMode: true,
			includeCavemanHook: true,
			strictMcpConfig: false,
		}));

		assert.equal(resolveExternalConfigValue("fastMode", project).value, true);
		assert.equal(resolveExternalConfigValue("strictMcpConfig", project).value, false);
		assert.equal(resolveExternalConfigValue("includeCavemanHook", project).value, true);

		const config = loadConfig(project);
		assert.equal(config.provider?.fastMode, true);
		assert.equal(config.provider?.strictMcpConfig, false);
		assert.equal(config.promptContext?.includeCavemanHook, true);
	}));

	it("drops values the loader would normalize away", () => withTempDirs(({ user, project }) => {
		writeFileSync(join(user, "claude-bridge.json"), JSON.stringify({
			provider: { connectorWriteMode: "read-only", forceEffort: "ultracode" },
		}));

		assert.equal(resolveExternalConfigValue("forceEffort", project).explicit, false);
		assert.equal(resolveExternalConfigValue("connectorWriteMode", project).explicit, false);
		assert.equal(loadConfig(project).provider?.forceEffort, undefined);
	}));

	it("ignores the project legacy file in isolated mode", () => withTempDirs(({ user, project }) => {
		writeFileSync(join(user, "claude-bridge.json"), JSON.stringify({ enabled: false }));
		writeFileSync(join(project, ".pi", "claude-bridge.json"), JSON.stringify({ enabled: true }));
		recordProjectTrust({ cwd: project, isProjectTrusted: () => true });
		process.env.CLAUDE_BRIDGE_ISOLATED = "1";

		const resolved = resolveExternalConfigValue("enabled", project);
		assert.equal(resolved.value, false);
		assert.equal(resolved.source, join(user, "claude-bridge.json"));
		assert.equal(loadConfig(project).enabled, false);
	}));

	it("ignores an untrusted project legacy file", () => withTempDirs(({ user, project }) => {
		writeFileSync(join(user, "claude-bridge.json"), JSON.stringify({ enabled: false }));
		writeFileSync(join(project, ".pi", "claude-bridge.json"), JSON.stringify({ enabled: true }));

		assert.equal(resolveExternalConfigValue("enabled", project).value, false);
	}));

	it("reports only non-manager channels, since manager config outranks them", () => withTempDirs(({ user, project }) => {
		writeFileSync(join(user, "settings.json"), JSON.stringify({
			vstack: { extensionManager: { config: { "@vanillagreen/pi-claude-bridge": { enabled: true, fastMode: true } } } },
		}));

		assert.equal(resolveExternalConfigValue("enabled", project).explicit, false);
		assert.equal(resolveExternalConfigValue("fastMode", project).explicit, false);
	}));

	it("reports no value for keys it does not own", () => withTempDirs(({ user, project }) => {
		writeFileSync(join(user, "claude-bridge.json"), JSON.stringify({ enabled: false }));

		assert.deepEqual(resolveExternalConfigValue("glyphStyle", project), { explicit: false, value: undefined });
	}));
});
