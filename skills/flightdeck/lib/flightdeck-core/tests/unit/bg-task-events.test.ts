// Unit test (reviewer-test #13): the daemon consumes a pi-bg-task-exit
// wake-events row identically to other canonical adapter events:
//   - isCanonicalTag("pi-bg-task-exit") is true
//   - appendEvent persists the row + extends WAKE_PENDING.in_flight
//   - details payload carries event_type + task fields verbatim
// This is the parser/consumer-side mirror of the subscriber parity test
// in tests/parity/pi-subscriber-bg-task.test.ts.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { appendEvent, isCanonicalTag } from "../../src/daemon/events.ts";

let dir = "";
function path(n: string): string { return join(dir, n); }

beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "fd-bg-task-")); });
afterEach(() => { if (dir) rmSync(dir, { recursive: true, force: true }); });

describe("pi-bg-task-exit daemon consumption", () => {
	test("classified canonical", () => {
		expect(isCanonicalTag("pi-bg-task-exit")).toBe(true);
	});

	test("appendEvent persists pi-bg-task-exit row with task payload in details", () => {
		const ef = path("events.jsonl");
		const wp = path("wake.pending");
		const sl = path("session.lock");
		const taskPayload = {
			event_type: "bg-task-exit",
			task: { id: "bg-3", status: "failed", exitCode: null, command: "bot-review-wait 81", outputBytes: 89 },
			harness: "pi",
		};
		const ok = appendEvent({
			paneId: "%18", hash: "abcd12345678", tag: "pi-bg-task-exit", reason: "pi-bg-task-exit-event",
			sessionLock: sl, eventsFile: ef, wakePending: wp, lastEventKey: new Map(),
			extraJson: JSON.stringify(taskPayload),
		});
		expect(ok).toBe(true);
		const row = JSON.parse(readFileSync(ef, "utf8").trim());
		expect(row.tag).toBe("pi-bg-task-exit");
		expect(row.reason).toBe("pi-bg-task-exit-event");
		expect(row.pane_id).toBe("%18");
		expect(row.details.event_type).toBe("bg-task-exit");
		expect(row.details.task.id).toBe("bg-3");
		expect(row.details.task.status).toBe("failed");
	});

	test("appendEvent extends WAKE_PENDING.in_flight when present", () => {
		const ef = path("events.jsonl");
		const wp = path("wake.pending");
		const sl = path("session.lock");
		writeFileSync(wp, JSON.stringify({ delivered_at_epoch: 1000, in_flight: [] }));
		appendEvent({
			paneId: "%18", hash: "h-bg-3", tag: "pi-bg-task-exit", reason: "pi-bg-task-exit-event",
			sessionLock: sl, eventsFile: ef, wakePending: wp, lastEventKey: new Map(),
			extraJson: JSON.stringify({ event_type: "bg-task-exit", task: { id: "bg-3" } }),
		});
		const wpObj = JSON.parse(readFileSync(wp, "utf8"));
		expect(wpObj.in_flight).toEqual([{ pane_id: "%18", hash: "h-bg-3", tag: "pi-bg-task-exit", is_bell: false }]);
	});

	test("dedup: repeated (pane,hash,tag) returns false", () => {
		const ef = path("events.jsonl");
		const sl = path("session.lock");
		const seen = new Map<string, true>();
		expect(appendEvent({
			paneId: "%18", hash: "h-bg-3", tag: "pi-bg-task-exit", reason: "pi-bg-task-exit-event",
			sessionLock: sl, eventsFile: ef, wakePending: path("wp"), lastEventKey: seen,
			extraJson: JSON.stringify({ event_type: "bg-task-exit", task: { id: "bg-3", status: "failed" } }),
		})).toBe(true);
		expect(appendEvent({
			paneId: "%18", hash: "h-bg-3", tag: "pi-bg-task-exit", reason: "pi-bg-task-exit-event",
			sessionLock: sl, eventsFile: ef, wakePending: path("wp"), lastEventKey: seen,
			extraJson: JSON.stringify({ event_type: "bg-task-exit", task: { id: "bg-3", status: "failed" } }),
		})).toBe(false);
		const lines = readFileSync(ef, "utf8").split("\n").filter(Boolean);
		expect(lines.length).toBe(1);
	});
});
