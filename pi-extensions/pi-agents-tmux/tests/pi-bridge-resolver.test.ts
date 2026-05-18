import assert from "node:assert/strict";
import test from "node:test";

import { createCachedPiBridgeResolver } from "../extensions/subagent/pane.js";

test("cached pi-bridge resolver resolves once immediately and reuses the path", async () => {
	let calls = 0;
	const resolve = createCachedPiBridgeResolver(async () => {
		calls += 1;
		return `/tmp/pi-bridge-${calls}`;
	});

	assert.equal(calls, 1);
	assert.equal(await resolve(), "/tmp/pi-bridge-1");
	assert.equal(await resolve(), "/tmp/pi-bridge-1");
	assert.equal(calls, 1);
});

test("cached pi-bridge resolver treats startup resolution failures as missing", async () => {
	let calls = 0;
	const resolve = createCachedPiBridgeResolver(async () => {
		calls += 1;
		throw new Error("resolver failed");
	});

	assert.equal(calls, 1);
	assert.equal(await resolve(), undefined);
	assert.equal(await resolve(), undefined);
	assert.equal(calls, 1);
});
