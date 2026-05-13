// Unit tests: appendEvent dedup + extend-in-flight + isCanonicalTag.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { appendEvent, isCanonicalTag } from "../../src/daemon/events.ts";

let dir = "";
function path(n: string): string { return join(dir, n); }

beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "fd-events-")); });
afterEach(() => { if (dir) rmSync(dir, { recursive: true, force: true }); });

describe("appendEvent", () => {
	test("appends a single JSONL row", () => {
		const ef = path("events.jsonl");
		const wp = path("wake.pending");
		const sl = path("session.lock");
		const seen = new Map<string, true>();
		const ok = appendEvent({
			paneId: "%101", hash: "h1", tag: "merge-now", reason: "stable",
			ageSec: 5, isBell: false, sessionLock: sl, eventsFile: ef,
			wakePending: wp, lastEventKey: seen,
		});
		expect(ok).toBe(true);
		expect(existsSync(ef)).toBe(true);
		const row = JSON.parse(readFileSync(ef, "utf8").trim());
		expect(row.pane_id).toBe("%101");
		expect(row.hash).toBe("h1");
		expect(row.tag).toBe("merge-now");
		expect(row.reason).toBe("stable");
		expect(row.stable_age_sec).toBe(5);
		expect(seen.has("%101|h1|merge-now")).toBe(true);
	});

	test("dedup: same (pane,hash,tag) key returns false on second call", () => {
		const ef = path("events.jsonl");
		const wp = path("wake.pending");
		const sl = path("session.lock");
		const seen = new Map<string, true>();
		expect(appendEvent({ paneId: "%101", hash: "h1", tag: "bell", reason: "x",
			sessionLock: sl, eventsFile: ef, wakePending: wp, lastEventKey: seen })).toBe(true);
		expect(appendEvent({ paneId: "%101", hash: "h1", tag: "bell", reason: "different",
			sessionLock: sl, eventsFile: ef, wakePending: wp, lastEventKey: seen })).toBe(false);
		const lines = readFileSync(ef, "utf8").split("\n").filter(Boolean);
		expect(lines.length).toBe(1);
	});

	test("different (pane,hash,tag) tuples are distinct", () => {
		const ef = path("events.jsonl");
		const sl = path("session.lock");
		const seen = new Map<string, true>();
		appendEvent({ paneId: "%101", hash: "h1", tag: "bell", reason: "x",
			sessionLock: sl, eventsFile: ef, wakePending: path("wp"), lastEventKey: seen });
		appendEvent({ paneId: "%101", hash: "h1", tag: "merge-now", reason: "y",
			sessionLock: sl, eventsFile: ef, wakePending: path("wp"), lastEventKey: seen });
		appendEvent({ paneId: "%102", hash: "h1", tag: "bell", reason: "z",
			sessionLock: sl, eventsFile: ef, wakePending: path("wp"), lastEventKey: seen });
		const lines = readFileSync(ef, "utf8").split("\n").filter(Boolean);
		expect(lines.length).toBe(3);
	});

	test("extends in_flight when WAKE_PENDING exists", () => {
		const ef = path("events.jsonl");
		const wp = path("wake.pending");
		const sl = path("session.lock");
		writeFileSync(wp, JSON.stringify({ delivered_at_epoch: 1000, in_flight: [{ pane_id: "%99", hash: "h0", tag: "old", is_bell: false }] }));
		appendEvent({ paneId: "%101", hash: "h1", tag: "bell", reason: "x", isBell: true,
			sessionLock: sl, eventsFile: ef, wakePending: wp, lastEventKey: new Map() });
		const wpObj = JSON.parse(readFileSync(wp, "utf8"));
		expect(wpObj.in_flight.length).toBe(2);
		expect(wpObj.in_flight[1]).toEqual({ pane_id: "%101", hash: "h1", tag: "bell", is_bell: true });
	});

	test("extraJson payload becomes .details", () => {
		const ef = path("events.jsonl");
		const sl = path("session.lock");
		appendEvent({ paneId: "%101", hash: "h1", tag: "oc-question", reason: "oc-event",
			extraJson: JSON.stringify({ event_type: "question", request_id: "que_abc" }),
			sessionLock: sl, eventsFile: ef, wakePending: path("wp"), lastEventKey: new Map() });
		const row = JSON.parse(readFileSync(ef, "utf8").trim());
		expect(row.details).toEqual({ event_type: "question", request_id: "que_abc" });
	});
});

describe("appendEvent failure semantics (round-4 #6)", () => {
	test("unwritable events file → returns false + rolls back dedup", () => {
		// Force append to fail by pointing eventsFile at a path whose
		// parent directory doesn't exist. The bash child's `>> file`
		// will fail, append returns false, the dedup marker is removed.
		const ef = path("no-such-dir/events.jsonl");
		const sl = path("session.lock");
		const seen = new Map<string, true>();
		const ok = appendEvent({
			paneId: "%101", hash: "h1", tag: "merge-now", reason: "stable",
			sessionLock: sl, eventsFile: ef, wakePending: path("wp"), lastEventKey: seen,
		});
		expect(ok).toBe(false);
		// Dedup marker rolled back — the next attempt with the same key
		// should be allowed to retry (also false this time, but the
		// rollback is what matters).
		expect(seen.has("%101|h1|merge-now")).toBe(false);
	});
});

describe("isCanonicalTag", () => {
	test("known canonical tags return true", () => {
		for (const t of ["merge-now", "rebase-multi-choice", "bell-not-canonical", "oc-question", "modal-prompt"]) {
			const expected = t !== "bell-not-canonical";
			expect(isCanonicalTag(t)).toBe(expected);
		}
	});

	test("non-canonical (rendering/idle) returns false", () => {
		expect(isCanonicalTag("rendering")).toBe(false);
		expect(isCanonicalTag("idle")).toBe(false);
		expect(isCanonicalTag("")).toBe(false);
	});

	// Flightdeck cleanup-scope defensive tags (issue #18). Without these
	// in CANONICAL_TAGS the daemon stable-buffer path marks the hash
	// notified and never wakes master, so handle-prompt's `Keep` answer
	// never fires and the per-issue pane stalls on the destructive prompt.
	test("stale-no-pr-branch is canonical (issue #18)", () => {
		expect(isCanonicalTag("stale-no-pr-branch")).toBe(true);
	});

	test("stale-orphan-worktree is canonical (issue #18)", () => {
		expect(isCanonicalTag("stale-orphan-worktree")).toBe(true);
	});
});
