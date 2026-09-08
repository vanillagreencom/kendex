import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { DEFAULT_SETTINGS } from "../src/settings.js";

test("package settings defaults match runtime defaults", () => {
	const manifest = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
	const settings = manifest.kendex.extensionManager.settings as Array<{ key: keyof typeof DEFAULT_SETTINGS; default: unknown }>;
	const manifestDefaults = Object.fromEntries(settings.map((item) => [item.key, item.default]));
	assert.deepEqual(manifestDefaults, DEFAULT_SETTINGS);
});
