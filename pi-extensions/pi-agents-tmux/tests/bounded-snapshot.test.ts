import assert from "node:assert/strict";
import test from "node:test";
import {
	BOUNDED_SNAPSHOT_DEFAULT_MAX_BYTES,
	appendBoundedSnapshot,
	isBoundedSnapshotManifest,
} from "../extensions/subagent/session-persistence.js";

interface RecordedAppend { customType: string; data: unknown }

function recorder() {
	const calls: RecordedAppend[] = [];
	const appender = { appendEntry: <T>(customType: string, data: T) => { calls.push({ customType, data }); } };
	return { appender, calls };
}

test("appendBoundedSnapshot appends the full payload when within the cap", () => {
	const { appender, calls } = recorder();
	const cache = new Map<string, string>();
	const outcome = appendBoundedSnapshot({
		appender,
		customType: "vstack-subagents:runtime-state",
		payload: { version: 1, panes: {}, tasks: {}, updatedAt: "2026-05-20T05:00:00.000Z" },
		fingerprintInput: { panes: {}, tasks: {} },
		sessionKey: "session-a",
		fingerprintCache: cache,
	});
	assert.equal(outcome.appended, true);
	assert.equal(outcome.reason, "appended");
	assert.equal(calls.length, 1);
	assert.deepEqual(calls[0].data, { version: 1, panes: {}, tasks: {}, updatedAt: "2026-05-20T05:00:00.000Z" });
	assert.equal(cache.get("session-a"), outcome.fingerprint);
});

test("appendBoundedSnapshot skips an unchanged fingerprint", () => {
	const { appender, calls } = recorder();
	const cache = new Map<string, string>();
	const opts = {
		appender,
		customType: "vstack-subagents:runtime-state",
		payload: { version: 1 as const, panes: {}, tasks: {}, updatedAt: "2026-05-20T05:00:00.000Z" },
		fingerprintInput: { panes: {}, tasks: {} },
		sessionKey: "session-a",
		fingerprintCache: cache,
	};
	appendBoundedSnapshot(opts);
	const second = appendBoundedSnapshot({ ...opts, payload: { ...opts.payload, updatedAt: "2026-05-20T05:00:01.000Z" } });
	assert.equal(second.appended, false);
	assert.equal(second.reason, "unchanged");
	assert.equal(calls.length, 1);
});

test("appendBoundedSnapshot emits a manifest when the payload exceeds the cap", () => {
	const { appender, calls } = recorder();
	const cache = new Map<string, string>();
	// Build a registry that comfortably exceeds the 64 KiB cap: 200 task records with verbose summaries.
	const tasks: Record<string, { summary: string }> = {};
	for (let i = 0; i < 200; i += 1) {
		tasks[`task-${i}`] = { summary: "a".repeat(512) };
	}
	const payload = { version: 1 as const, panes: {}, tasks, updatedAt: "2026-05-20T05:00:00.000Z" };
	const outcome = appendBoundedSnapshot({
		appender,
		customType: "vstack-subagents:runtime-state",
		payload,
		fingerprintInput: { panes: {}, tasks },
		sessionKey: "session-a",
		fingerprintCache: cache,
		counts: () => ({ panes: 0, tasks: Object.keys(tasks).length }),
	});
	assert.equal(outcome.appended, true);
	assert.equal(outcome.reason, "manifest");
	assert.ok(outcome.byteSize > BOUNDED_SNAPSHOT_DEFAULT_MAX_BYTES);
	assert.equal(calls.length, 1);
	const data = calls[0].data;
	assert.ok(isBoundedSnapshotManifest(data));
	assert.deepEqual((data as { counts: unknown }).counts, { panes: 0, tasks: 200 });
});

test("appendBoundedSnapshot can suppress manifests with manifestOnOverflow=false", () => {
	const { appender, calls } = recorder();
	const cache = new Map<string, string>();
	const tasks: Record<string, string> = {};
	for (let i = 0; i < 50; i += 1) tasks[`task-${i}`] = "a".repeat(2048);
	const outcome = appendBoundedSnapshot({
		appender,
		customType: "vstack-subagents:runtime-state",
		payload: { version: 1 as const, panes: {}, tasks, updatedAt: "x" },
		fingerprintInput: { tasks },
		sessionKey: "session-b",
		fingerprintCache: cache,
		manifestOnOverflow: false,
	});
	assert.equal(outcome.appended, false);
	assert.equal(outcome.reason, "unchanged");
	assert.equal(calls.length, 0);
	// Cache is updated so a subsequent identical payload also short-circuits without appending.
	assert.equal(cache.get("session-b"), outcome.fingerprint);
});

test("appendBoundedSnapshot emits a bounded manifest under the cap even when the payload is many MB (vstack#183)", () => {
	const { appender, calls } = recorder();
	const cache = new Map<string, string>();
	// Build a registry well above 64 KiB — ~1 MB of task records. Pre-fix
	// the manifest body would have embedded the full JSON as `fingerprint`
	// and reproduced the cap blow-up.
	const tasks: Record<string, { summary: string }> = {};
	for (let i = 0; i < 1000; i += 1) tasks[`task-${i}`] = { summary: "a".repeat(1024) };
	const payload = { version: 1 as const, panes: {}, tasks, updatedAt: "2026-05-20T05:00:00.000Z" };
	const outcome = appendBoundedSnapshot({
		appender,
		customType: "vstack-subagents:runtime-state",
		payload,
		fingerprintInput: { panes: {}, tasks },
		sessionKey: "session-c",
		fingerprintCache: cache,
		counts: () => ({ panes: 0, tasks: Object.keys(tasks).length }),
	});
	assert.equal(outcome.appended, true);
	assert.equal(outcome.reason, "manifest");
	const data = calls[0].data;
	assert.ok(isBoundedSnapshotManifest(data));
	const manifestBytes = Buffer.byteLength(JSON.stringify(data), "utf8");
	assert.ok(manifestBytes <= BOUNDED_SNAPSHOT_DEFAULT_MAX_BYTES, `manifest size ${manifestBytes}B exceeds cap ${BOUNDED_SNAPSHOT_DEFAULT_MAX_BYTES}B`);
	// The fingerprint must be a fixed-size hex digest, not the full canonical JSON.
	const fingerprint = (data as { fingerprint: string }).fingerprint;
	assert.match(fingerprint, /^[0-9a-f]+$/);
	assert.ok(fingerprint.length <= 128, `fingerprint length ${fingerprint.length} unexpectedly large`);
});

test("isBoundedSnapshotManifest only matches version 2 manifests", () => {
	assert.equal(isBoundedSnapshotManifest({ version: 1, panes: {}, tasks: {} }), false);
	assert.equal(isBoundedSnapshotManifest({ version: 2, fullSnapshot: false, reason: "payload-too-large", byteSize: 1, fingerprint: "x", counts: {}, updatedAt: "x" }), true);
	assert.equal(isBoundedSnapshotManifest(null), false);
});
