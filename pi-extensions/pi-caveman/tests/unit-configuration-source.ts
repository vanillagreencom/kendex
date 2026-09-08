import { test } from "node:test";
import assert from "node:assert/strict";
import { configurationSource, recordProjectTrust } from "../extensions/prompt.ts";
import { settingsFixture } from "./lib/settings-fixture.ts";

for (const source of ["default", "user", "project"] as const) {
	test(`configuration source ${source}`, (t) => {
		const fixture = settingsFixture(t);
		if (source !== "default") fixture.writeConfig(fixture.userPath, { "@vanillagreen/pi-caveman": { mode: "full" } });
		if (source === "project") {
			fixture.writeConfig(fixture.projectPath, { "@vanillagreen/pi-caveman": { mode: "lite" } });
			recordProjectTrust({ cwd: fixture.projectDir, isProjectTrusted: () => true });
		}
		const result = configurationSource(fixture.projectDir);
		assert.equal(result.source, source);
		assert.equal(result.path, source === "default" ? undefined : source === "user" ? fixture.userPath : fixture.projectPath);
	});
}
