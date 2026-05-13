import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
	partitionTerminationEntries,
	renderTerminationSummary,
} from "../../src/terminate/session-summary.ts";
import type { FlightdeckStateLike } from "../../src/state/types.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const TERMINATE_MD = resolve(HERE, "../../../../workflows/terminate.md");

function baseState(entries: Record<string, unknown>, issues: Record<string, unknown> = {}): FlightdeckStateLike {
	return {
		conflict_graph: { computed_at: null, edges: [] },
		entries,
		issues,
		merge_queue: [],
		paused_for_user: null,
		schema_version: 1.1,
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

	test("issue-only session produces the issue merge summary", () => {
		const state = baseState({ "FD-401": issueEntry() });
		const partition = partitionTerminationEntries(state);
		expect(partition.issueEntries.map((entry) => entry.id)).toEqual(["FD-401"]);
		expect(partition.genericEntries).toEqual([]);

		const output = renderTerminationSummary(state, opts);
		expect(output).toContain("### ✈️ Flightdeck session complete");
		expect(output).toContain("**Outcomes**");
		expect(output).toContain("| FD-401 | merged | #401 | abcdef123456 | 2 |");
		expect(output).toContain("**Next-cycle recommendation**");
		expect(output).not.toContain("### ✈️ Flightdeck sessions complete");
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

			const output = renderTerminationSummary(state, opts);
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

	test("mixed session produces generic and issue summaries", () => {
		const state = baseState({
			"FD-401": issueEntry(),
			"scratch-pi": adhocEntry(),
		});
		const partition = partitionTerminationEntries(state);
		expect(partition.issueEntries.map((entry) => entry.id)).toEqual(["FD-401"]);
		expect(partition.genericEntries.map((entry) => entry.id)).toEqual(["scratch-pi"]);

		const output = renderTerminationSummary(state, opts);
		expect(output).toContain("### ✈️ Flightdeck sessions complete");
		expect(output).toContain("| scratch-pi | adhoc | complete | pi | 1 |");
		expect(output).toContain("### ✈️ Flightdeck session complete");
		expect(output).toContain("| FD-401 | merged | #401 | abcdef123456 | 2 |");
	});

	test("workflow doc routes termination by tracked-entry kind", () => {
		const doc = readFileSync(TERMINATE_MD, "utf8");
		expect(doc).toContain("Partition tracked entries by kind");
		expect(doc).toContain("If `ISSUE_ENTRIES` is non-empty");
		expect(doc).toContain("If `ISSUE_ENTRIES` is empty and `GENERIC_ENTRIES` is non-empty");
		expect(doc).toContain("For mixed sessions");
		expect(doc).toContain("Do not call `gh`, `linear`, worktree helpers, merge planning, or `project-management`");
	});
});
