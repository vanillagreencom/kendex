import { describe, expect, test } from "bun:test";
import {
	DEFAULT_OUTPUT_WAKE_BUDGET_MAX_BYTES,
	DEFAULT_OUTPUT_WAKE_BUDGET_MAX_WAKES,
} from "../extensions/constants.js";
import { restoredTaskFromSnapshot, taskSnapshot } from "../extensions/snapshot.js";
import type { WakeDiagnostic } from "../extensions/types.js";
import { shouldEmitOutputWake } from "../extensions/wake-events.js";
import { fakeIdent, fakeTask } from "./fixtures/lifecycle.js";

describe("output wake budget persistence", () => {
	test("retains each budget and restore state before the wake decision", () => {
		const now = 1_700_000_001_000;
		const limits = {
			maxBytes: DEFAULT_OUTPUT_WAKE_BUDGET_MAX_BYTES,
			maxWakes: DEFAULT_OUTPUT_WAKE_BUDGET_MAX_WAKES,
		};
		const rows = [
			{
				name: "serialized nonzero budget retains capacity after a live restore",
				task: fakeTask({ id: "bg-budget-roundtrip", pid: 4242, procIdent: fakeIdent(4242),
					status: "running", notifyMode: "always", notifyOnOutput: true, updatedAt: 1_700_000_000_500,
					outputWakeBudget: { wakes: 12, bytes: 4_096, exhausted: false, announcedAt: null } }),
				identity: fakeIdent(4242), decide: true,
				expected: {
					snapshotBudget: { wakes: 12, bytes: 4_096, exhausted: false, announcedAt: null },
					restored: { status: "running", closed: false, stopReason: null, updatedAt: 1_700_000_000_500,
						budget: { wakes: 12, bytes: 4_096, exhausted: false, announcedAt: null } },
					probedPids: [4242], decision: { allowed: true, diagnostics: [] },
				},
			},
			{
				name: "nonzero budget survives a dead-process restore",
				task: fakeTask({ id: "bg-budget-roundtrip", pid: 4242, procIdent: fakeIdent(4242),
					status: "running", notifyMode: "always", notifyOnOutput: true, updatedAt: 1_700_000_000_500,
					outputWakeBudget: { wakes: 19, bytes: 18_000, exhausted: false, announcedAt: null } }),
				identity: null, decide: false,
				expected: {
					snapshotBudget: { wakes: 19, bytes: 18_000, exhausted: false, announcedAt: null },
					restored: { status: "stopped", closed: true, stopReason: "shutdown", updatedAt: now,
						budget: { wakes: 19, bytes: 18_000, exhausted: false, announcedAt: null } },
					probedPids: [4242], decision: null,
				},
			},
			{
				name: "exhausted budget retains its announcement and suppresses a live restored task",
				task: fakeTask({ id: "bg-budget-roundtrip", pid: 4242, procIdent: fakeIdent(4242),
					status: "running", notifyMode: "always", notifyOnOutput: true, updatedAt: 1_700_000_000_500,
					outputWakeBudget: { wakes: limits.maxWakes, bytes: limits.maxBytes, exhausted: true, announcedAt: 1_700_000_000_400 } }),
				identity: fakeIdent(4242), decide: true,
				expected: {
					snapshotBudget: { wakes: limits.maxWakes, bytes: limits.maxBytes, exhausted: true, announcedAt: 1_700_000_000_400 },
					restored: { status: "running", closed: false, stopReason: null, updatedAt: 1_700_000_000_500,
						budget: { wakes: limits.maxWakes, bytes: limits.maxBytes, exhausted: true, announcedAt: 1_700_000_000_400 } },
					probedPids: [4242], decision: { allowed: false, diagnostics: [{
						eventAt: now, eventType: "output", sequence: 99, taskId: "bg-budget-roundtrip",
						taskStatus: "running", timestamp: now, reason: "wake-budget-exhausted",
					}] },
				},
			},
			{
				name: "absent budget restores every zero-state field",
				task: fakeTask({ id: "bg-without-budget", pid: 1, status: "completed", notifyMode: "always",
					notifyOnOutput: false, updatedAt: 1, outputWakeBudget: undefined }),
				identity: null, decide: false,
				expected: {
					snapshotBudget: undefined,
					restored: { status: "completed", closed: true, stopReason: null, updatedAt: 1,
						budget: { wakes: 0, bytes: 0, exhausted: false, announcedAt: null } },
					probedPids: [], decision: null,
				},
			},
		];
		expect.assertions(rows.length + 1);
		expect(rows.length, "wake budget persistence table must contain cases").toBeGreaterThan(0);
		for (const row of rows) {
			const snapshot = taskSnapshot(row.task);
			const probedPids: number[] = [];
			const restored = restoredTaskFromSnapshot(snapshot, {
				now, identityProbe: (pid) => { probedPids.push(pid); return row.identity; },
			});
			// Capture fields before the wake helper can normalize or change live state.
			const restoredBeforeDecision = {
				status: restored.status, closed: restored.closed, stopReason: restored.stopReason,
				updatedAt: restored.updatedAt,
				budget: restored.outputWakeBudget === undefined ? undefined : { ...restored.outputWakeBudget },
			};
			const diagnostics: WakeDiagnostic[] = [];
			const decision = row.decide ? {
				allowed: shouldEmitOutputWake(restored, {
					eventAt: now, now: () => now, newOutput: "more\n", newOutputTail: "more\n",
					patternMatched: true, sequence: 99, wakeBudgetLimits: limits,
					logDiagnostic: (diagnostic) => diagnostics.push({
						eventAt: diagnostic.eventAt, eventType: diagnostic.eventType, sequence: diagnostic.sequence,
						taskId: diagnostic.taskId, taskStatus: diagnostic.taskStatus,
						timestamp: diagnostic.timestamp, reason: diagnostic.reason,
					}),
				}),
				diagnostics,
			} : null;
			expect({ snapshotBudget: snapshot.outputWakeBudget, restored: restoredBeforeDecision, probedPids, decision }, row.name).toStrictEqual(row.expected);
		}
	});
});
