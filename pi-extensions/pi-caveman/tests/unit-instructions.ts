import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { instructions } from "../extensions/prompt.ts";
import { settingsFixture } from "./lib/settings-fixture.ts";

const SNAP_DIR = join(dirname(fileURLToPath(import.meta.url)), "__snapshots__");
const UPDATE = process.env.UPDATE_SNAPSHOTS === "1";

for (const mode of ["lite", "full", "ultra", "micro"] as const) {
	for (const clarity of [false, true]) {
		for (const boundariesOn of [true, false]) {
			const name = `${mode}-${clarity ? "clarity" : "clean"}-boundaries-${boundariesOn ? "on" : "off"}`;
			test(`renders complete bridge prompt ${name}`, (t) => {
				const fixture = settingsFixture(t);
				fixture.writeConfig(fixture.userPath, { "@vanillagreen/pi-caveman": {
					mode, boundaryNormalForCode: boundariesOn, boundaryNormalForCommits: boundariesOn,
					boundaryNormalForReviews: boundariesOn, boundaryNormalForExternalWrites: boundariesOn,
				} });
				const rendered = instructions(mode, fixture.projectDir, clarity);
				const path = join(SNAP_DIR, `${name}.txt`);
				if (UPDATE) {
					mkdirSync(dirname(path), { recursive: true });
					writeFileSync(path, rendered);
				} else {
					assert.equal(rendered, readFileSync(path, "utf8"));
				}
			});
		}
	}
}

for (const clarity of [false, true]) {
	test(`off mode emits no prompt with clarity=${clarity}`, (t) => {
		const fixture = settingsFixture(t);
		fixture.writeConfig(fixture.userPath, { "@vanillagreen/pi-caveman": { mode: "off" } });
		assert.equal(instructions("off", fixture.projectDir, clarity), "");
	});
}

test("custom suffix is part of the complete bridge prompt", (t) => {
	const fixture = settingsFixture(t);
	fixture.writeConfig(fixture.userPath, { "@vanillagreen/pi-caveman": { mode: "full", customPromptSuffix: "PROJECT-SUFFIX-SENTINEL" } });
	const expectedLines = readFileSync(join(SNAP_DIR, "full-clean-boundaries-on.txt"), "utf8").split("\n");
	expectedLines.splice(-1, 0, "PROJECT-SUFFIX-SENTINEL");
	assert.equal(instructions("full", fixture.projectDir, false), expectedLines.join("\n"));
});
