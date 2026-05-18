import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
	partitionTerminationEntries,
	renderGenericTerminationSummaryFromState,
} from "../../src/terminate/session-summary.ts";
import type { FlightdeckStateLike } from "../../src/state/types.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const TERMINATE_MD = resolve(HERE, "../../../../workflows/linear/terminate.md");

function baseState(entries: Record<string, unknown>, issues: Record<string, unknown> = {}): FlightdeckStateLike {
	return {
		conflict_graph: { computed_at: null, edges: [] },
		entries,
		issues,
		merge_queue: [],
		paused_for_user: null,
		session_id: "TERM",
		started_at: "2026-05-13T00:00:00Z",
		terminated: false,
	};
}

function issueEntry(id = "FD-401"): Record<string, unknown> {
	return {
		id,
		title: "Issue workflow",
		kind: "issue",
		state: "merged",
		harness: "pi",
		cwd: "/repo/trees/fd-401",
		pane_id: "%401",
		pane_target: "TERM:4.0",
		domain: {
			issue: {
				id,
				worktree: "/repo/trees/fd-401",
				pr_number: 401,
				merge_commit: "abcdef1234567890",
			},
		},
		decisions_log: [
			{ ts: "2026-05-13T00:10:00Z", prompt_tag: "merge-now", answer: "Merge" },
			{ ts: "2026-05-13T00:12:00Z", prompt_tag: "terminal-state-reached", answer: "merged" },
		],
		merge_commit: "abcdef1234567890",
	};
}

function legacyIssueShapedEntry(id = "FD-402"): Record<string, unknown> {
	return {
		id,
		title: "Issue-shaped malformed entry",
		state: "merged",
		harness: "pi",
		pr_number: 402,
		worktree: "/repo/trees/fd-402",
		merge_commit: "fedcba6543210000",
		decisions_log: [
			{ ts: "2026-05-13T00:12:00Z", prompt_tag: "terminal-state-reached", answer: "merged" },
		],
	};
}

function adhocEntry(id = "scratch-pi"): Record<string, unknown> {
	return {
		id,
		title: "Scratch Pi",
		kind: "adhoc",
		state: "complete",
		harness: "pi",
		cwd: "/repo",
		pane_id: "%77",
		pane_target: "TERM:7.0",
		decisions_log: [
			{ ts: "2026-05-13T00:05:00Z", prompt_tag: "terminal-state-reached", answer: "complete" },
		],
	};
}

describe("terminate session summary split", () => {
	const opts = {
		session: "TERM",
		summaryPath: "tmp/flightdeck-summary-TERM-2026-05-13T001500Z.md",
		timestamp: "2026-05-13T00:15:00Z",
	};

	test("issue-only session routes to the existing issue markdown path, not the generic TS renderer", () => {
		const state = baseState({ "FD-401": issueEntry() });
		const partition = partitionTerminationEntries(state);
		expect(partition.issueEntries.map((entry) => entry.id)).toEqual(["FD-401"]);
		expect(partition.genericEntries).toEqual([]);

		const output = renderGenericTerminationSummaryFromState(state, opts);
		expect(output).toBe("");

		const doc = readFileSync(TERMINATE_MD, "utf8");
		expect(doc).toContain("For issue entries, emit the existing issue summary block");
		expect(doc).toContain("**Issues created this session**");
		expect(doc).toContain("**Next-cycle recommendation**");
		expect(doc).toContain("[For each recommended issue from § 4:]");
	});

	test("adhoc-only session produces generic session summary without issue dependencies", () => {
		const oldGh = process.env.GH_TOKEN;
		const oldGithub = process.env.GITHUB_TOKEN;
		const oldLinear = process.env.LINEAR_API_KEY;
		delete process.env.GH_TOKEN;
		delete process.env.GITHUB_TOKEN;
		delete process.env.LINEAR_API_KEY;
		try {
			const state = baseState({ "scratch-pi": adhocEntry() });
			const partition = partitionTerminationEntries(state);
			expect(partition.issueEntries).toEqual([]);
			expect(partition.genericEntries.map((entry) => entry.id)).toEqual(["scratch-pi"]);

			const output = renderGenericTerminationSummaryFromState(state, opts);
			expect(output).toContain("### ✈️ Flightdeck sessions complete");
			expect(output).toContain("**Tracked sessions**");
			expect(output).toContain("| scratch-pi | adhoc | complete | pi | 1 |");
			expect(output).toContain("**Counts**: 1 sessions · 1 complete · 0 cancelled · 0 dead");
			expect(output).not.toContain("**Outcomes**");
			expect(output).not.toContain("Next-cycle recommendation");
		} finally {
			if (oldGh === undefined) delete process.env.GH_TOKEN; else process.env.GH_TOKEN = oldGh;
			if (oldGithub === undefined) delete process.env.GITHUB_TOKEN; else process.env.GITHUB_TOKEN = oldGithub;
			if (oldLinear === undefined) delete process.env.LINEAR_API_KEY; else process.env.LINEAR_API_KEY = oldLinear;
		}
	});

	test("mixed session produces generic TS summary and leaves issue entries for markdown path", () => {
		const state = baseState({
			"FD-401": issueEntry(),
			"scratch-pi": adhocEntry(),
		});
		const partition = partitionTerminationEntries(state);
		expect(partition.issueEntries.map((entry) => entry.id)).toEqual(["FD-401"]);
		expect(partition.genericEntries.map((entry) => entry.id)).toEqual(["scratch-pi"]);

		const output = renderGenericTerminationSummaryFromState(state, opts);
		expect(output).toContain("### ✈️ Flightdeck sessions complete");
		expect(output).toContain("| scratch-pi | adhoc | complete | pi | 1 |");
		expect(output).not.toContain("| FD-401 |");
	});

	test("issue-shaped entries without issue kind/domain fail closed into issue path with warning", () => {
		const warnings: string[] = [];
		const state = baseState({ "FD-402": legacyIssueShapedEntry() });
		const partition = partitionTerminationEntries(state, { warn: (message) => warnings.push(message) });
		expect(partition.issueEntries.map((entry) => entry.id)).toEqual(["FD-402"]);
		expect(partition.genericEntries).toEqual([]);
		expect(warnings).toHaveLength(1);
		expect(warnings[0]).toContain("issue-shaped tracked entry");
		expect(warnings[0]).toContain("routing through issue termination path");
		expect(warnings[0]).toContain("domain issue key");
		expect(warnings[0]).toContain("merge_commit");
		expect(warnings[0]).not.toContain("pr_number");

		const output = renderGenericTerminationSummaryFromState(state, { ...opts, warn: () => undefined });
		expect(output).toBe("");
	});


	test("workflow entries with generic PR metadata stay in generic termination path", () => {
		const state = baseState({
			"workflow-pr": {
				id: "workflow-pr",
				title: "Workflow PR",
				kind: "workflow",
				state: "complete",
				harness: "pi",
				pr_number: 117,
				worktree: "/repo/trees/issue-117",
			},
		});
		const partition = partitionTerminationEntries(state);
		expect(partition.issueEntries).toEqual([]);
		expect(partition.genericEntries.map((entry) => entry.id)).toEqual(["workflow-pr"]);
	});

	test("github_issue domain entries route to issue termination path", () => {
		const state = baseState({
			"120": {
				id: "120",
				title: "GitHub issue workflow",
				kind: "issue",
				state: "merged",
				harness: "pi",
				domain: {
					github_issue: {
						number: 120,
						url: "https://github.com/owner/repo/issues/120",
						worktree: "/repo/trees/120",
						pr_number: 220,
						merge_commit: "abc123",
					},
				},
			},
		});
		const partition = partitionTerminationEntries(state);
		expect(partition.issueEntries.map((entry) => entry.id)).toEqual(["120"]);
		expect(partition.genericEntries).toEqual([]);
	});

	test("empty tracked entries produce explicit empty-session diagnostic", () => {
		const state = baseState({});
		const partition = partitionTerminationEntries(state);
		expect(partition.entryCount).toBe(0);
		expect(partition.issueEntries).toEqual([]);
		expect(partition.genericEntries).toEqual([]);

		const output = renderGenericTerminationSummaryFromState(state, opts);
		expect(output).toContain("### ✈️ Flightdeck session complete");
		expect(output).toContain("Session terminated with no tracked entries.");
		expect(output).toContain("**Counts**: 0 sessions · 0 complete · 0 cancelled · 0 dead");
	});

	test("workflow doc routes termination by tracked-entry kind and documents empty sessions", () => {
		const doc = readFileSync(TERMINATE_MD, "utf8");
		expect(doc).toContain("Partition tracked entries by kind");
		expect(doc).toContain("If `ISSUE_ENTRIES` is non-empty");
		expect(doc).toContain("If `ISSUE_ENTRIES` is empty and `GENERIC_ENTRIES` is non-empty");
		expect(doc).toContain("If both partitions are empty");
		expect(doc).toContain("For mixed sessions");
		expect(doc).toContain("Do not call `gh`, `linear`, worktree helpers, merge planning, or `project-management`");
	});
});
