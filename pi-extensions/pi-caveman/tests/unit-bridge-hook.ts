import { test } from "node:test";
import assert from "node:assert/strict";
import { bridgeCavemanHookEnabled } from "../extensions/prompt.ts";
import { settingsFixture } from "./lib/settings-fixture.ts";

for (const value of [true, undefined] as const) {
	test(`bridge hook setting ${String(value)}`, (t) => {
		const fixture = settingsFixture(t);
		fixture.writeConfig(fixture.userPath, {
			"@vanillagreen/pi-caveman": { mode: "full" },
			...(value === undefined ? {} : { "@vanillagreen/pi-claude-bridge": { includeCavemanHook: value } }),
		});
		assert.equal(bridgeCavemanHookEnabled(fixture.projectDir), value);
	});
}
