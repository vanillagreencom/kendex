import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
	BG_TASKS_SNAPSHOT_MAX_BYTES,
	createPersistence,
	isBgTasksBoundedManifest,
	type BgTasksBoundedManifest,
	type PersistenceDeps,
	type PersistencePayload,
} from "../extensions/persistence.js";
import type { BackgroundTaskSnapshot } from "../extensions/types.js";
import { boundedSnapshot } from "./fixtures/bounded-snapshot.js";

function withPersistenceContext(run: (ctx: NonNullable<ReturnType<PersistenceDeps["getActiveCtx"]>>, sidecarFile: string) => void): void {
	const root = mkdtempSync(join(tmpdir(), "pi-bg-bounded-"));
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	const previousDiagnosticLog = process.env.PI_BG_TASK_DIAGNOSTIC_LOG;
	try {
		const piDir = join(root, "agent");
		process.env.PI_CODING_AGENT_DIR = piDir;
		process.env.PI_BG_TASK_DIAGNOSTIC_LOG = join(root, "diagnostics.log");
		const ctx = {
			cwd: root,
			sessionManager: {
				getSessionId: () => "session",
				getSessionFile: () => join(root, "session.jsonl"),
			},
		} as NonNullable<ReturnType<PersistenceDeps["getActiveCtx"]>>;
		run(ctx, join(piDir, "kendex", "sessions", "session", "pi-background-tasks", "state.json"));
	} finally {
		if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousPiDir;
		if (previousDiagnosticLog === undefined) delete process.env.PI_BG_TASK_DIAGNOSTIC_LOG;
		else process.env.PI_BG_TASK_DIAGNOSTIC_LOG = previousDiagnosticLog;
		rmSync(root, { recursive: true, force: true });
	}
}

test("snapshot append decisions follow content changes", () => {
	expect.hasAssertions();
	withPersistenceContext((ctx, sidecarFile) => {
		const appended: { customType: string; payload: unknown }[] = [];
		let snapshots: BackgroundTaskSnapshot[] = [];
		const persistence = createPersistence({
			customType: "kendex-background-tasks:state",
			getActiveCtx: () => ctx,
			listSnapshots: () => snapshots,
			pi: { appendEntry: (customType: string, payload: unknown) => appended.push({ customType, payload }) } as PersistenceDeps["pi"],
		});
		for (const { name, status, updatedAt, appendReason, count } of [
			{ name: "first snapshot appends", status: "running", updatedAt: 1, appendReason: "appended", count: 1 },
			{ name: "identical snapshot does not append again", status: "running", updatedAt: 1, appendReason: "unchanged", count: 1 },
			{ name: "changed snapshot appends again", status: "completed", updatedAt: 3, appendReason: "appended", count: 2 },
		] as const) {
			snapshots = [boundedSnapshot({ status, updatedAt })];
			const result = persistence.persistSnapshots();
			const sidecar = JSON.parse(readFileSync(sidecarFile, "utf8")) as PersistencePayload;
			expect({ result, appendCount: appended.length, sidecarTasks: sidecar.tasks }, name).toEqual({
				result: { appendEntry: true, sidecar: true, appendReason },
				appendCount: count,
				sidecarTasks: snapshots,
			});
		}
	});
});

test("oversized snapshots append a bounded manifest", () => {
	expect.hasAssertions();
	for (const { name, taskCount } of [
		{ name: "completed tasks with large commands", taskCount: 70 },
		{ name: "large task list keeps a bounded fingerprint", taskCount: 1000 },
	] as const) {
		withPersistenceContext((ctx, sidecarFile) => {
			const snapshots = Array.from({ length: taskCount }, (_, index) => boundedSnapshot({
				id: `bg-${index}`,
				command: "x".repeat(10 * 1024),
				logFile: `/tmp/bg-${index}.log`,
			}));
			const appended: { customType: string; payload: unknown }[] = [];
			const persistence = createPersistence({
				customType: "kendex-background-tasks:state",
				getActiveCtx: () => ctx,
				listSnapshots: () => snapshots,
				pi: { appendEntry: (customType: string, payload: unknown) => appended.push({ customType, payload }) } as PersistenceDeps["pi"],
			});
			const result = persistence.persistSnapshots();
			const payload = appended[0]?.payload as BgTasksBoundedManifest | undefined;
			const sidecar = JSON.parse(readFileSync(sidecarFile, "utf8")) as PersistencePayload;
			expect({
				result,
				appendCount: appended.length,
				manifest: isBgTasksBoundedManifest(payload),
				taskCount: payload?.counts?.tasks,
				originalExceedsCap: typeof payload?.byteSize === "number" && payload.byteSize > BG_TASKS_SNAPSHOT_MAX_BYTES,
				manifestFitsCap: Buffer.byteLength(JSON.stringify(payload ?? null), "utf8") <= BG_TASKS_SNAPSHOT_MAX_BYTES,
				fingerprint: payload?.fingerprint,
				fingerprintFitsCap: typeof payload?.fingerprint === "string" && payload.fingerprint.length <= 128,
				sidecarMatches: JSON.stringify(sidecar.tasks) === JSON.stringify(snapshots),
			}, name).toEqual({
				result: { appendEntry: true, sidecar: true, appendReason: "manifest" },
				appendCount: 1,
				manifest: true,
				taskCount,
				originalExceedsCap: true,
				manifestFitsCap: true,
				fingerprint: expect.stringMatching(/^[0-9a-f]+$/),
				fingerprintFitsCap: true,
				sidecarMatches: true,
			});
		});
	}
});
