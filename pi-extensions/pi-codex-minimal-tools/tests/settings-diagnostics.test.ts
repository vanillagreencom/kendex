import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { settingsDiagnostics } from "../src/settings.js";
import { environment, world } from "./helpers/world.js";

test("settingsDiagnostics identifies the malformed settings file", (t) => {
	const { cwd, agent } = world(t);
	environment(t, { PI_CODING_AGENT_DIR: agent });
	writeFileSync(join(agent, "settings.json"), "{");
	const diagnostics = settingsDiagnostics(cwd);
	assert.equal(diagnostics.length, 1);
	assert.ok(diagnostics[0]!.includes(join(agent, "settings.json")));
});
