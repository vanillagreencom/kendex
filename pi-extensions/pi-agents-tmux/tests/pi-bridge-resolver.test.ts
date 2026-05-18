import assert from "node:assert/strict";
import test from "node:test";

import { createCachedPiBridgeResolver } from "../extensions/subagent/pane.js";

function resolverError(): Error {
	return Object.assign(new Error("resolver failed"), {
		code: "ENOENT",
		errno: -2,
		syscall: "spawn",
		path: "/missing/pi-bridge",
		cwd: "/tmp/cwd",
	});
}

test("cached pi-bridge resolver resolves once immediately and reuses the path", async () => {
	let calls = 0;
	const warnings: string[] = [];
	const resolve = createCachedPiBridgeResolver(async () => {
		calls += 1;
		return `/tmp/pi-bridge-${calls}`;
	}, (message) => warnings.push(message));

	assert.equal(calls, 1);
	assert.equal(await resolve(), "/tmp/pi-bridge-1");
	assert.equal(await resolve(), "/tmp/pi-bridge-1");
	assert.equal(calls, 1);
	assert.equal(warnings.length, 0);
});

test("cached pi-bridge resolver logs startup throw once and caches missing", async () => {
	let calls = 0;
	const warnings: string[] = [];
	const resolve = createCachedPiBridgeResolver(async () => {
		calls += 1;
		throw resolverError();
	}, (message) => warnings.push(message));

	assert.equal(calls, 1);
	assert.equal(await resolve(), undefined);
	assert.equal(await resolve(), undefined);
	assert.equal(calls, 1);
	assert.equal(warnings.length, 1);
	assert.match(warnings[0]!, /code=ENOENT/);
	assert.match(warnings[0]!, /errno=-2/);
	assert.match(warnings[0]!, /syscall=spawn/);
	assert.match(warnings[0]!, /path=\/missing\/pi-bridge/);
	assert.match(warnings[0]!, /cwd=\/tmp\/cwd/);
});

test("cached pi-bridge resolver logs returned undefined once and caches missing", async () => {
	let calls = 0;
	const warnings: string[] = [];
	const resolve = createCachedPiBridgeResolver(async () => {
		calls += 1;
		return undefined;
	}, (message) => warnings.push(message));

	assert.equal(calls, 1);
	assert.equal(await resolve(), undefined);
	assert.equal(await resolve(), undefined);
	assert.equal(calls, 1);
	assert.deepEqual(warnings, ["pi-bridge resolver failed: returned undefined"]);
});
