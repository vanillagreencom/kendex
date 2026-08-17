import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after } from "node:test";
import {
	persistRetryMarker,
	retryMarkerActive,
	retryMarkerPath,
} from "../extensions/subagent/rate-limit-retry-marker.js";

const TMP = mkdtempSync(join(tmpdir(), "retry-marker-"));
after(() => rmSync(TMP, { force: true, recursive: true }));

test("a written marker is active until one grace window past its retry time", () => {
	const at = 1_000_000;
	persistRetryMarker(TMP, "planner", at);
	assert.ok(existsSync(retryMarkerPath(TMP, "planner")));
	assert.equal(retryMarkerActive(TMP, "planner", at - 500, 300_000), true);
	assert.equal(retryMarkerActive(TMP, "planner", at + 299_999, 300_000), true);
	// A child that died mid-wait cannot park its pane forever.
	assert.equal(retryMarkerActive(TMP, "planner", at + 300_000, 300_000), false);
});

test("clearing removes the marker; absent, unparseable, and foreign markers read inactive", () => {
	persistRetryMarker(TMP, "reviewer", 5_000);
	persistRetryMarker(TMP, "reviewer", null);
	assert.equal(existsSync(retryMarkerPath(TMP, "reviewer")), false);
	assert.equal(retryMarkerActive(TMP, "reviewer", 0, 300_000), false);
	assert.equal(retryMarkerActive(TMP, "never-written", 0, 300_000), false);
	persistRetryMarker(TMP, "odd", Number.NaN);
	assert.equal(retryMarkerActive(TMP, "odd", 0, 300_000), false);
});

test("persist and clear never throw on an unwritable root", () => {
	assert.doesNotThrow(() => persistRetryMarker("/proc/definitely/not/writable", "x", 1));
	assert.doesNotThrow(() => persistRetryMarker("/proc/definitely/not/writable", "x", null));
	assert.equal(retryMarkerActive("/proc/definitely/not/writable", "x", 0, 1), false);
});
