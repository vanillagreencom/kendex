import { test } from "node:test";
import assert from "node:assert/strict";
import { settingSourcesForQuery } from "../src/connectors.ts";
import { assertSourceControl } from "./lib/source-control.mjs";

// Project settings carry env and apiKeyHelper. Connector sessions load user
// settings unless a caller explicitly selects other sources.
test("query settings respect connector isolation and explicit sources", () => {
	const rows = [
		[true, true, undefined, ["user"]], [true, false, undefined, ["user"]],
		[true, true, ["user", "project"], ["user", "project"]], [true, true, [], []],
		[false, true, undefined, undefined], [false, true, ["user"], ["user"]],
		[false, true, ["user", "project"], ["user", "project"]], [false, true, [], []],
		[false, false, undefined, ["user", "project"]], [false, false, ["user", "local"], ["user", "local"]],
	];
	for (const [connectors, append, sources, expected] of rows) {
		const actual = settingSourcesForQuery(connectors, append, sources);
		assert.deepEqual(actual, expected, JSON.stringify([connectors, append, sources]));
		if (sources !== undefined) assert.equal(actual, sources, "explicit sources pass through verbatim");
	}
});

test("must-fail control: configured sources cannot be dropped by prompt appending", () => {
	assertSourceControl({
		source: "src/connectors.ts",
		before: 'return configured ?? (appendSystemPrompt ? undefined : ["user", "project"]);',
		after: 'return appendSystemPrompt ? undefined : configured ?? ["user", "project"];',
		suite: "unit-connector-settings.mjs",
		pattern: "query settings respect connector isolation and explicit sources",
		failure: /\[false,true,\["user"\]\]/,
	});
});
