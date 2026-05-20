import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
	BG_TASKS_SNAPSHOT_MAX_BYTES,
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

	test("manifest restores degrade gracefully: restore loop does not wipe sidecar state", () => {
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
});
