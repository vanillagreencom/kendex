import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { GUARD_SETTING_NAMES } from "../extensions/hooks.ts";

// This is the shipped catalog bundle, not a test runner configuration.
// A toggle must name a hook that the catalog bundle can install.
test("guard toggles name hooks in the installable bundle", () => {
	const manifest = Bun.TOML.parse(readFileSync(join(import.meta.dir, "../../..", "kendex.toml"), "utf8")) as { bundles: Record<string, { hooks: string[] }> };
	for (const name of GUARD_SETTING_NAMES) expect(manifest.bundles["commit-guards"].hooks).toContain(name);
});
