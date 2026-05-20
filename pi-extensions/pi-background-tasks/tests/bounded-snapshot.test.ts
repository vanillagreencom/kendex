import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
	BG_TASKS_SNAPSHOT_MAX_BYTES,
	applyCustomEntryWithBarrier,
	createPersistence,
	isBgTasksBoundedManifest,
} from "../extensions/persistence.js";
import type { BackgroundTaskSnapshot } from "../extensions/types.js";

function fakeSnapshot(overrides: Partial<BackgroundTaskSnapshot> = {}): BackgroundTaskSnapshot {
	return {
		command: "printf ready",
		cwd: "/tmp/worktree",
		exitCode: null,
		exitNotified: false,
		expiresAt: null,
		id: overrides.id ?? "bg-1",
		lastOutputAt: 0,
		logFile: "/tmp/bg-1.log",
		notifyMode: "always",
		notifyOnExit: true,
		notifyOnOutput: false,
		outputBytes: 0,
		pid: 1234,
		startedAt: 1_700_000_000_000,
		status: "completed",
		title: "fake task",
		updatedAt: 1_700_000_000_500,
		voidedWakeSequences: [],
		wakeEvents: [],
		wakeSequence: 0,
		...overrides,
	};
}

function fakeCtx(sessionId: string) {
	const tempDir = mkdtempSync(join(tmpdir(), "pi-bg-persistence-"));
	return {
		cwd: tempDir,
		sessionManager: {
			getSessionId: () => sessionId,
			getSessionFile: () => join(tempDir, `${sessionId}.jsonl`),
		},
	} as any;
}

describe("pi-background-tasks bounded snapshots", () => {
	test("appendEntry skips identical successive task lists and re-fires on real change", () => {
		const appended: { customType: string; payload: any }[] = [];
		const ctx = fakeCtx("session-stable");
		const stable: BackgroundTaskSnapshot = fakeSnapshot({ id: "bg-1", status: "running", updatedAt: 1 });
		let snapshots: BackgroundTaskSnapshot[] = [stable];
		const persistence = createPersistence({
			customType: "vstack-background-tasks:state",
			getActiveCtx: () => ctx,
			listSnapshots: () => snapshots,
			pi: { appendEntry: (customType: string, payload: any) => appended.push({ customType, payload }) } as any,
		});

		const first = persistence.persistSnapshots();
		const second = persistence.persistSnapshots();
		expect(first.appendEntry).toBe(true);
		expect(first.appendReason).toBe("appended");
		expect(second.appendEntry).toBe(true);
		expect(second.appendReason).toBe("unchanged");
		expect(appended).toHaveLength(1);

		// Actual content change appends again.
		snapshots = [fakeSnapshot({ id: "bg-1", status: "completed", updatedAt: 3 })];
		const third = persistence.persistSnapshots();
		expect(third.appendReason).toBe("appended");
		expect(appended).toHaveLength(2);
	});

	test("payloads over the byte cap downgrade to a bounded manifest", () => {
		const appended: { customType: string; payload: any }[] = [];
		const ctx = fakeCtx("session-bloated");
		// 70 completed tasks each carrying a 10 KiB heredoc command (vstack#177).
		const heredoc = "x".repeat(10 * 1024);
		const snapshots: BackgroundTaskSnapshot[] = Array.from({ length: 70 }, (_value, index) => fakeSnapshot({
			id: `bg-${index}`,
			command: heredoc,
			logFile: `/tmp/bg-${index}.log`,
			status: "completed",
		}));
		const persistence = createPersistence({
			customType: "vstack-background-tasks:state",
			getActiveCtx: () => ctx,
			listSnapshots: () => snapshots,
			pi: { appendEntry: (customType: string, payload: any) => appended.push({ customType, payload }) } as any,
		});
		const result = persistence.persistSnapshots();
		expect(result.appendReason).toBe("manifest");
		expect(appended).toHaveLength(1);
		expect(isBgTasksBoundedManifest(appended[0].payload)).toBe(true);
		expect(appended[0].payload.counts.tasks).toBe(70);
		expect(appended[0].payload.byteSize).toBeGreaterThan(BG_TASKS_SNAPSHOT_MAX_BYTES);
	});

	test("bounded manifest itself stays under the byte cap regardless of payload size (vstack#183)", () => {
		const appended: { customType: string; payload: any }[] = [];
		const ctx = fakeCtx("session-massive");
		// ~10 MB worst case: 1000 tasks * 10 KiB heredoc command each.
		const heredoc = "x".repeat(10 * 1024);
		const snapshots: BackgroundTaskSnapshot[] = Array.from({ length: 1000 }, (_value, index) => fakeSnapshot({
			id: `bg-${index}`,
			command: heredoc,
			logFile: `/tmp/bg-${index}.log`,
			status: "completed",
		}));
		const persistence = createPersistence({
			customType: "vstack-background-tasks:state",
			getActiveCtx: () => ctx,
			listSnapshots: () => snapshots,
			pi: { appendEntry: (customType: string, payload: any) => appended.push({ customType, payload }) } as any,
		});
		const result = persistence.persistSnapshots();
		expect(result.appendReason).toBe("manifest");
		expect(appended).toHaveLength(1);
		const manifestBytes = Buffer.byteLength(JSON.stringify(appended[0].payload), "utf8");
		expect(manifestBytes).toBeLessThanOrEqual(BG_TASKS_SNAPSHOT_MAX_BYTES);
		// Fingerprint must be a fixed-size hex digest, not the full canonical JSON.
		const fingerprint = appended[0].payload.fingerprint as string;
		expect(fingerprint).toMatch(/^[0-9a-f]+$/);
		expect(fingerprint.length).toBeLessThanOrEqual(128);
	});

	test("manifest type guard matches v2 fullSnapshot:false envelope only", () => {
		const manifest = {
			version: 2,
			fullSnapshot: false,
			reason: "payload-too-large" as const,
			byteSize: 999_999,
			fingerprint: "abc",
			counts: { tasks: 70 },
			updatedAt: Date.now(),
		};
		expect(isBgTasksBoundedManifest(manifest)).toBe(true);
		expect(isBgTasksBoundedManifest({ version: 1, tasks: [], updatedAt: 0 })).toBe(false);
	});

	test("vstack#184: restore barrier - manifest entry re-applies sidecar state", () => {
		// Repro shape: branch contains [older-full-snapshot, later bounded
		// manifest]. Sidecar has the latest task set ("bg-new"). Pre-fix the
		// older full snapshot replaced the sidecar state and the manifest
		// was skipped, regressing canonical state to "bg-old". The barrier
		// helper now restores the sidecar when it hits the manifest.
		const sidecarTasks: BackgroundTaskSnapshot[] = [fakeSnapshot({ id: "bg-new", status: "completed" })];
		const olderTasks: BackgroundTaskSnapshot[] = [fakeSnapshot({ id: "bg-old", status: "completed" })];
		let current: BackgroundTaskSnapshot[] = [];
		const clear = () => { current = []; };
		const apply = (snapshot: BackgroundTaskSnapshot) => { current.push(snapshot); };

		// Sidecar restore happened first (current = sidecar tasks).
		current = [...sidecarTasks];

		// Branch entry #1: older full snapshot. Expected to replace.
		applyCustomEntryWithBarrier({
			data: { tasks: olderTasks, updatedAt: 1 },
			sidecarLoaded: true,
			sidecarTasks,
			clear,
			apply,
		});
		expect(current.map((t) => t.id)).toEqual(["bg-old"]);

		// Branch entry #2: bounded manifest. Expected to restore sidecar.
		applyCustomEntryWithBarrier({
			data: { version: 2, fullSnapshot: false, reason: "payload-too-large", byteSize: 999_999, fingerprint: "abc", counts: { tasks: 1 }, updatedAt: 2 },
			sidecarLoaded: true,
			sidecarTasks,
			clear,
			apply,
		});
		expect(current.map((t) => t.id)).toEqual(["bg-new"]);
	});

	test("vstack#184: barrier without sidecar leaves state untouched (no crash)", () => {
		let current: BackgroundTaskSnapshot[] = [fakeSnapshot({ id: "bg-pre", status: "completed" })];
		const clear = () => { current = []; };
		const apply = (snapshot: BackgroundTaskSnapshot) => { current.push(snapshot); };
		applyCustomEntryWithBarrier({
			data: { version: 2, fullSnapshot: false, reason: "payload-too-large", byteSize: 1, fingerprint: "x", counts: { tasks: 0 }, updatedAt: 0 },
			sidecarLoaded: false,
			sidecarTasks: undefined,
			clear,
			apply,
		});
		// Sidecar load failed earlier; manifest is a no-op so state is preserved.
		expect(current.map((t) => t.id)).toEqual(["bg-pre"]);
	});

	test("vstack#184: forward-compat - any fullSnapshot:false manifest counts as barrier", () => {
		const sidecarTasks: BackgroundTaskSnapshot[] = [fakeSnapshot({ id: "bg-sidecar" })];
		let current: BackgroundTaskSnapshot[] = [fakeSnapshot({ id: "bg-old" })];
		const clear = () => { current = []; };
		const apply = (snapshot: BackgroundTaskSnapshot) => { current.push(snapshot); };
		applyCustomEntryWithBarrier({
			// Hypothetical future version 3 manifest.
			data: { version: 3, fullSnapshot: false, reason: "some-new-reason" },
			sidecarLoaded: true,
			sidecarTasks,
			clear,
			apply,
		});
		expect(current.map((t) => t.id)).toEqual(["bg-sidecar"]);
	});
});
