import { test } from "node:test";
import assert from "node:assert/strict";
import { settingSourcesForQuery } from "../bundle/index.js";

// Project settings carry env and apiKeyHelper. Connector sessions load user
// settings unless a caller explicitly selects other sources.
test("query settings respect connector isolation and explicit sources", () => {
	const rows = [
		[true, true, undefined, ["user"]], [true, false, undefined, ["user"]],
		[true, true, ["user", "project"], ["user", "project"]], [true, true, [], []],
		[false, true, undefined, undefined], [false, true, ["user"], undefined],
		[false, false, undefined, ["user", "project"]], [false, false, ["user", "local"], ["user", "local"]],
	];
	for (const [connectors, append, sources, expected] of rows) {
		assert.deepEqual(settingSourcesForQuery(connectors, append, sources), expected, JSON.stringify([connectors, append, sources]));
	}
});
