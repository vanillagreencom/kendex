import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { DEFAULT_SETTINGS } from "../src/settings.js";

const manifest = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const settings: Array<{ key: string; default: unknown }> = manifest.kendex.extensionManager.settings;
const defaults = Object.fromEntries(settings.map((item) => [item.key, item.default]));
for (const { key, expected } of [
	{ key: "enabled", expected: DEFAULT_SETTINGS.enabled },
	{ key: "defaultProvider", expected: DEFAULT_SETTINGS.defaultProvider },
	{ key: "enabledProviders", expected: DEFAULT_SETTINGS.enabledProviders.join(",") },
	{ key: "nativeOpenAiWebSearch", expected: DEFAULT_SETTINGS.nativeOpenAiWebSearch },
	{ key: "githubClone.enabled", expected: DEFAULT_SETTINGS.githubClone.enabled },
]) {
	test(`manifest default: ${key}`, () => assert.equal(defaults[key], expected));
}
test("manifest exposes only implemented runtime keys", () => {
	assert.deepEqual(settings.map(({ key }) => ({
		key,
		implemented: key.split(".").reduce<unknown>((value, part) => value && typeof value === "object" ? (value as Record<string, unknown>)[part] : undefined, DEFAULT_SETTINGS) !== undefined,
		forbidden: /curator|activity|shortcut|summaryModel|includeContentByDefault/i.test(key),
	})), settings.map(({ key }) => ({ key, implemented: true, forbidden: false })));
});
