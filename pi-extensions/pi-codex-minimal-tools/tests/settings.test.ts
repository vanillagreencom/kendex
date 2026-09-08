import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { loadSettings, recordProjectTrust } from "../src/settings.js";
import { environment, world } from "./helpers/world.js";

for (const row of [
	{
		name: "user then project, invalid model falls back",
		user: { autoEnable: false, imageOutputDir: "user-images", imageModel: "gpt-image-1" },
		project: { autoEnable: true, imageOutputDir: "project-images", imageModel: "bad-model", directImageApiFallback: true },
		steps: [{ trust: true, expected: { autoEnable: true, imageOutputDir: "project-images", imageModel: "gpt-image-2", directImageApiFallback: true, applyPatchEnabled: true } }],
	},
	{
		name: "project settings require trust",
		user: { autoEnable: false }, project: { autoEnable: true },
		steps: [{ trust: false, expected: { autoEnable: false } }, { trust: true, expected: { autoEnable: true } }],
	},
]) {
	test(`loadSettings: ${row.name}`, (t) => {
		const { cwd, agent } = world(t);
		environment(t, { PI_CODING_AGENT_DIR: agent });
		for (const [file, config] of [[join(agent, "settings.json"), row.user], [join(cwd, ".pi", "settings.json"), row.project]] as const) {
			writeFileSync(file, JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-codex-minimal-tools": config } } } }));
		}
		for (const step of row.steps) {
			recordProjectTrust({ cwd, isProjectTrusted: () => step.trust });
			const settings = loadSettings(cwd);
			assert.deepEqual(Object.fromEntries(Object.keys(step.expected).map((key) => [key, settings[key as keyof typeof settings]])), step.expected);
		}
	});
}
