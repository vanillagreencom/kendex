import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { loadSettings, recordProjectTrust, settingsDiagnostics } from "../src/settings.js";
import { isolateEnvironment, settingsEnvironment, tempDir } from "./fixtures.js";

function config(path: string, value: Record<string, unknown>): void {
	writeFileSync(path, JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-web-tools": value } } } }));
}

for (const row of [
	{
		name: "user/project/private precedence and process override",
		run(root: string, user: string, project: string) {
			const privatePath = join(root, "private.json");
			writeFileSync(privatePath, JSON.stringify({ exaApiKey: "private-exa", perplexityApiKey: "private-pplx" }));
			config(join(user, "settings.json"), { autoEnable: false, enabledProviders: "exa,openai-native", webToolsConfigFile: privatePath });
			config(join(project, ".pi", "settings.json"), { autoEnable: true, defaultProvider: "exa", githubClone: { maxRepoSizeMB: 100 }, exaResearchModes: { standard: { numResults: 9 } } });
			process.env.EXA_API_KEY = "env-exa";
			recordProjectTrust({ cwd: project, isProjectTrusted: () => true });
			const result = loadSettings(project);
			return [result.autoEnable, result.defaultProvider, result.enabledProviders, result.githubClone.maxRepoSizeMB, result.exaResearchModes.standard, result.apiKeys.exa, result.apiKeys.perplexity];
		},
		expected: [true, "exa", ["exa", "openai-native"], 100, { numResults: 9 }, "env-exa", "private-pplx"],
	},
	{
		name: "project config waits for recorded trust",
		run(_root: string, user: string, project: string) {
			config(join(user, "settings.json"), { autoEnable: false });
			config(join(project, ".pi", "settings.json"), { autoEnable: true });
			recordProjectTrust({ cwd: project, isProjectTrusted: () => false });
			const untrusted = loadSettings(project).autoEnable;
			recordProjectTrust({ cwd: project, isProjectTrusted: () => true });
			return [untrusted, loadSettings(project).autoEnable];
		},
		expected: [false, true],
	},
	{
		name: "malformed JSON diagnostic",
		run(_root: string, user: string, project: string) {
			writeFileSync(join(user, "settings.json"), "{");
			return [settingsDiagnostics(project).length];
		},
		expected: [1],
	},
	{
		name: "JSON string research mode override",
		run(_root: string, user: string, project: string) {
			config(join(user, "settings.json"), { exaResearchModes: JSON.stringify({ lite: { numResults: 3, summaryQuery: "fast" } }) });
			return [loadSettings(project).exaResearchModes.lite];
		},
		expected: [{ numResults: 3, summaryQuery: "fast" }],
	},
	{
		name: "dotenv trust and process precedence",
		run(_root: string, _user: string, project: string) {
			writeFileSync(join(project, ".env.local"), 'EXA_API_KEY="env-file-exa"\nPERPLEXITY_API_KEY=env-file-pplx\n');
			recordProjectTrust({ cwd: project, isProjectTrusted: () => false });
			const untrusted = loadSettings(project);
			recordProjectTrust({ cwd: project, isProjectTrusted: () => true });
			const trusted = loadSettings(project);
			process.env.EXA_API_KEY = "process-exa";
			return [untrusted.apiKeys.exa, untrusted.apiKeys.perplexity, trusted.apiKeys.exa, trusted.apiKeys.perplexity, loadSettings(project).apiKeys.exa];
		},
		expected: [undefined, undefined, "env-file-exa", "env-file-pplx", "process-exa"],
	},
]) {
	test(`settings: ${row.name}`, (t) => {
		isolateEnvironment(t, settingsEnvironment);
		const root = tempDir(t);
		const user = join(root, "agent");
		const project = join(root, "project");
		mkdirSync(user);
		mkdirSync(join(project, ".pi"), { recursive: true });
		process.env.PI_CODING_AGENT_DIR = user;
		assert.deepEqual(row.run(root, user, project), row.expected);
	});
}
