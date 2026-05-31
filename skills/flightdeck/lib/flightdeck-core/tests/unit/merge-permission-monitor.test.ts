import { describe, expect, test } from "bun:test";

import {
	collectMergePermissionWakeCandidates,
	MERGE_PERMISSION_BLOCKED_TAG,
	MERGE_PERMISSION_MONITOR_INTERVAL_SEC,
	MERGE_PERMISSION_MONITOR_REASON,
} from "../../src/daemon/merge-permission-monitor.ts";

describe("merge permission monitor", () => {
	test("collects ready entries with permission markers across domains", () => {
		const candidates = collectMergePermissionWakeCandidates({
			nowSec: 120,
			state: {
				entries: {
					"gh-288": {
						domain: { github_issue: { merge_blocked_permission: { pr: 101 }, number: 288, pr_number: 101, url: "https://example.invalid/288", worktree: "/wt", merge_commit: null } },
						id: "gh-288",
						kind: "issue",
						pane_id: "%101",
						state: "ready",
					},
					"plan-a": {
						domain: { plan_item: { phase: "merge-blocked-permission", plan_path: "plan.md", plan_title: "Plan", item_id: "A", item_title: "A", depends_on: [], worktree: "/wt-a", pr_number: 202, merge_commit: null } },
						id: "plan-a",
						kind: "workflow",
						state: "ready",
					},
					"lin-1": {
						domain: { issue: { id: "LIN-1", merge_blocked_permission: { pr: "303" }, pr_number: 303 } },
						id: "lin-1",
						kind: "issue",
						pane_id: "%303",
						state: "merge-ready",
					},
				},
			},
		});

		expect(candidates).toHaveLength(3);
		expect(candidates.map((c) => c.pr).sort((a, b) => a - b)).toEqual([101, 202, 303]);
		expect(candidates[0]?.hash).toMatch(/^[0-9a-f]{12}$/);
		expect(candidates.every((c) => c.details.event_type === MERGE_PERMISSION_MONITOR_REASON)).toBe(true);
		expect(MERGE_PERMISSION_BLOCKED_TAG).toBe("merge-permission-blocked");
	});

	test("throttles per entry/domain/pr key and changes hash by interval bucket", () => {
		const state = {
			entries: {
				"gh-288": {
					domain: { github_issue: { merge_blocked_permission: { pr: 101 }, number: 288, pr_number: 101, url: "https://example.invalid/288", worktree: "/wt", merge_commit: null } },
					id: "gh-288",
					kind: "issue",
					pane_id: "%101",
					state: "ready",
				},
			},
		};
		const lastWakeByKey = new Map<string, number>();
		const first = collectMergePermissionWakeCandidates({ state, nowSec: 10, intervalSec: 60, lastWakeByKey });
		expect(first).toHaveLength(1);
		lastWakeByKey.set(first[0]!.key, 10);
		expect(collectMergePermissionWakeCandidates({ state, nowSec: 69, intervalSec: 60, lastWakeByKey })).toHaveLength(0);
		const second = collectMergePermissionWakeCandidates({ state, nowSec: 70, intervalSec: 60, lastWakeByKey });
		expect(second).toHaveLength(1);
		expect(second[0]!.hash).not.toBe(first[0]!.hash);
		expect(MERGE_PERMISSION_MONITOR_INTERVAL_SEC).toBe(60);
	});

	test("ignores terminal states and entries without PR numbers", () => {
		const candidates = collectMergePermissionWakeCandidates({
			nowSec: 1,
			state: {
				entries: {
					merged: { id: "merged", kind: "issue", state: "merged", domain: { issue: { id: "LIN-1", pr_number: 1, merge_blocked_permission: { pr: 1 } } } },
					missing_pr: { id: "missing_pr", kind: "issue", state: "ready", domain: { issue: { id: "LIN-2", merge_blocked_permission: { reason: "denied" } } } },
				},
			},
		});
		expect(candidates).toEqual([]);
	});
});
