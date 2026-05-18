import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ISSUE_ONLY_TAGS } from "../../src/classifier/rules.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURES = resolve(HERE, "../fixtures/prompt-classify");
const TS_SCRIPT = resolve(HERE, "../../src/bin/prompt-classify.ts");
const HANDLER_DOC = resolve(HERE, "../../../../workflows/shared/session-handle-prompt.md");
const GITHUB_HANDLE_DOC = resolve(HERE, "../../../../workflows/github/handle-prompt.md");
const GITHUB_CLOSE_DOC = resolve(HERE, "../../../../workflows/github/close-issue.md");
const GITHUB_WATCH_DOC = resolve(HERE, "../../../../workflows/github/watch.md");
const PLAN_START_DOC = resolve(HERE, "../../../../workflows/plan/start.md");
const PLAN_HANDLE_DOC = resolve(HERE, "../../../../workflows/plan/handle-prompt.md");
const PLAN_CLOSE_DOC = resolve(HERE, "../../../../workflows/plan/close-item.md");
const PLAN_WATCH_DOC = resolve(HERE, "../../../../workflows/plan/watch.md");
const PLAN_TERMINATE_DOC = resolve(HERE, "../../../../workflows/plan/terminate.md");

const GENERIC_PROMPT = `Choose the next action.

1. Continue
2. Ask for help

Enter to select
`;

const ISSUE_ONLY_CASES: Array<{ tag: string; fixture: string }> = [
	{ tag: "force-merge-confirm", fixture: "12-force-merge-confirm.buffer" },
	{ tag: "merge-ready-but-unknown", fixture: "13-merge-ready-but-unknown.buffer" },
	{ tag: "merge-now", fixture: "14-merge-now.buffer" },
	{ tag: "bot-review-wait-stuck", fixture: "15-bot-review-stuck.buffer" },
	{ tag: "rebase-multi-choice", fixture: "16-rebase-multi-choice.buffer" },
	{ tag: "force-push-prompt", fixture: "17-force-push-prompt.buffer" },
	{ tag: "cleanup-prompt", fixture: "18-cleanup-prompt.buffer" },
	{ tag: "stale-no-pr-branch", fixture: "18a-stale-no-pr-branch.buffer" },
	{ tag: "stale-orphan-worktree", fixture: "18b-stale-orphan-worktree.buffer" },
	{ tag: "audit-relation-prompt", fixture: "19-audit-relation.buffer" },
	{ tag: "descope-related", fixture: "20-descope-related.buffer" },
	{ tag: "external-fix-suggestions", fixture: "21-external-fix-suggestions.buffer" },
	{ tag: "cycle-fix-suggestions", fixture: "22-cycle-fix-suggestions.buffer" },
	{ tag: "multi-select-tabbed", fixture: "23-multi-select-tabbed.buffer" },
];

function fixture(file: string): string {
	return readFileSync(join(FIXTURES, file), "utf8");
}

function runClassify(input: string, args: string[] = []): { stdout: string; stderr: string; status: number | null } {
	const r = spawnSync("bun", ["run", TS_SCRIPT, ...args], { encoding: "utf8", input });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function expectTag(input: string, args: string[], expected: string): ReturnType<typeof runClassify> {
	const result = runClassify(input, args);
	expect(result.status).toBe(0);
	expect(result.stdout.trim()).toBe(expected);
	return result;
}

describe("handler domain guards", () => {
	for (const { tag, fixture: fixtureName } of ISSUE_ONLY_CASES) {
		test(`${tag} on adhoc escalates, on issue routes normally`, () => {
			const input = fixture(fixtureName);
			const adhoc = expectTag(input, ["--entry-kind", "adhoc"], "domain-mismatch");
			expect(adhoc.stderr).toContain(`issue-only prompt tag ${tag}`);

			const issue = expectTag(input, ["--entry-kind", "issue"], tag);
			expect(issue.stderr).toBe("");
		});
	}

	test("entry kind unknown sentinel escalates issue-only prompt as domain-mismatch", () => {
		const result = expectTag(fixture("14-merge-now.buffer"), ["--entry-kind-unknown"], "domain-mismatch");
		expect(result.stderr).toContain("issue-only prompt tag merge-now");
	});

	test("missing entry kind fails closed by default", () => {
		const result = expectTag(fixture("14-merge-now.buffer"), [], "domain-mismatch");
		expect(result.stderr).toContain("classified without --entry-kind");
		expect(result.stderr).toContain("routing as domain-mismatch");
	});

	test("generic tag on issue entry remains generic for the generic handler", () => {
		expectTag(GENERIC_PROMPT, ["--entry-kind", "issue"], "generic-multi-choice");
	});

	test("computed issue-only tags are present in the guard set", () => {
		expect(ISSUE_ONLY_TAGS.has("scope-creep-detected")).toBe(true);
	});

	test("generic bash-permission allowlist is restricted to Flightdeck/read-only commands", () => {
		const doc = readFileSync(HANDLER_DOC, "utf8");
		expect(doc).toContain("(flightdeck-state|flightdeck-daemon|flightdeck-dashboard|flightdeck-session|pane-registry|pane-poll|pane-respond|pane-clear-bell)");
		expect(doc).not.toContain(".agents/skills/.*/scripts");
		expect(doc).not.toContain(".agents/skills/*/scripts");
		expect(doc).toContain("generic mode does not require those CLIs");
		expect(doc).toContain("gh pr view");
		expect(doc).toContain("linear");
	});

	test("github merge-now requires CLEAN before answering Merge", () => {
		const doc = readFileSync(GITHUB_HANDLE_DOC, "utf8");
		expect(doc).toContain("gh pr view <PR> --json mergeStateStatus,reviewDecision,statusCheckRollup");
		expect(doc).toContain('mergeStateStatus === "CLEAN"');
		expect(doc).toContain("Predicate true → answer `Merge`");
		expect(doc).toContain('`mergeStateStatus === "UNKNOWN"`');
		expect(doc).toContain("Do not auto-Merge");
	});

	test("github close-issue requires authoritative merged PR and merge commit", () => {
		const doc = readFileSync(GITHUB_CLOSE_DOC, "utf8");
		expect(doc).toContain("Pane-buffer text alone is never sufficient");
		expect(doc).toContain("gh pr view <PR> --json state,mergeStateStatus,mergeCommit");
		expect(doc).toContain('state === "MERGED"');
		expect(doc).toContain("mergeCommit !== null");
		expect(doc).toContain("Pane text like `MERGED`");
		expect(doc).toContain("never closes an issue by itself");
		expect(doc.indexOf("gh pr view <PR> --json state,mergeStateStatus,mergeCommit")).toBeLessThan(doc.lastIndexOf("gh issue close <N> --reason completed"));
	});

	test("github force-merge handlers honor FLIGHTDECK_AUTO_MERGE=0", () => {
		const doc = readFileSync(GITHUB_HANDLE_DOC, "utf8");
		expect(doc).toContain('If `FLIGHTDECK_AUTO_MERGE=0`, set `paused_for_user = {issue_id:<N>, reason:"auto-merge-disabled", prompt_text:<buffer>}` and return.');
		expect(doc).toContain("Do not answer wait, Merge, force-merge, or transition to `force-merge-confirm` while auto-merge is disabled.");
		expect(doc).toContain("do not answer the force-merge option");
	});

	test("github force-merge predicate requires strict approval and UNKNOWN timer", () => {
		for (const doc of [readFileSync(GITHUB_HANDLE_DOC, "utf8"), readFileSync(GITHUB_WATCH_DOC, "utf8")]) {
			expect(doc).toContain('reviewDecision == "APPROVED"');
			expect(doc).toContain('do not substitute unset review with "no pending reviewers"');
			expect(doc).toContain("disjoint");
			expect(doc).toContain("unknown_since > FLIGHTDECK_FORCE_MERGE_AFTER_SECS");
		}
	});

	test("plan lane spawn docs forbid supervisor recursion and use native session launcher", () => {
		const docs = [PLAN_START_DOC, PLAN_HANDLE_DOC, PLAN_CLOSE_DOC, PLAN_WATCH_DOC, PLAN_TERMINATE_DOC]
			.map((path) => readFileSync(path, "utf8"));
		const combined = docs.join("\n---\n");
		expect(combined).toContain("flightdeck-session start");
		expect(combined).toContain("--kind workflow");
		expect(combined).toContain("Read tmp/brief.md and execute end-to-end. Print the PR URL as the LAST line.");
		expect(combined).not.toMatch(/\/skill:flightdeck plan|\$flightdeck plan|\/flightdeck plan (start|watch|close|terminate)/);
		expect(combined).not.toContain("/skill:");
	});

	test("plan lane docs carry PR safety gates from github redesign", () => {
		const handle = readFileSync(PLAN_HANDLE_DOC, "utf8");
		const close = readFileSync(PLAN_CLOSE_DOC, "utf8");
		const watch = readFileSync(PLAN_WATCH_DOC, "utf8");
		expect(handle).toContain('mergeStateStatus === "CLEAN"');
		expect(handle).toContain("FLIGHTDECK_AUTO_MERGE=0` gates `merge-now`, `merge-ready-but-unknown`, and `force-merge-confirm`");
		expect(handle).toContain("APPROVED ∧ all_checks_in {SUCCESS, SKIPPED} ∧ disjoint(PR_files, main_files_recently_changed) ∧ unknown_since > FLIGHTDECK_FORCE_MERGE_AFTER_SECS");
		expect(watch).toContain('If `FLIGHTDECK_AUTO_MERGE=0`, set `paused_for_user = {entry_id:<ITEM_ID>, reason:"auto-merge-disabled"');
		expect(watch).toContain('reviewDecision == "APPROVED"');
		expect(watch).toContain('do not substitute unset review with "no pending reviewers"');
		expect(close).toContain("Pane-buffer text alone is never sufficient");
		expect(close).toContain("gh pr view <PR> --json state,mergeStateStatus,mergeCommit");
		expect(close).toContain('state === "MERGED"');
		expect(close).toContain("mergeCommit !== null");
	});

	test("plan lane workflow prose uses placeholders instead of copied literals", () => {
		const combined = [PLAN_START_DOC, PLAN_HANDLE_DOC, PLAN_CLOSE_DOC, PLAN_WATCH_DOC, PLAN_TERMINATE_DOC]
			.map((path) => readFileSync(path, "utf8"))
			.join("\n");
		expect(combined).toContain("<ITEM_ID>");
		expect(combined).toContain("<PR>");
		expect(combined).not.toContain("vanillagreencom/vstack");
		expect(combined).not.toMatch(/issue-120|#120|\b120\b/);
	});

	test("plan start validates graph before dry-run or mutation", () => {
		const doc = readFileSync(PLAN_START_DOC, "utf8");
		expect(doc.indexOf("Validate the plan graph before dry-run preview")).toBeLessThan(doc.indexOf("<parse_preview_format>"));
		expect(doc).toContain('reason:"plan-parse-invalid"');
		expect(doc).toContain('prompt_text:"<ABSOLUTE_PLAN_PATH>: zero work items"');
		expect(doc).toContain('reason:"plan-dependency-unresolved"');
		expect(doc).toContain("depends on '<BAD_NAME>' which doesn't match any H2");
		expect(doc).toContain('reason:"plan-self-dependency"');
		expect(doc).toContain('prompt_text:"<ITEM_ID> depends on itself"');
		expect(doc).toContain('reason:"plan-dependency-cycle"');
		expect(doc).toContain('prompt_text:"cycle: <ITEM_A> -> <ITEM_B> -> <ITEM_A>"');
	});

	test("plan spawn docs require atomic claim and transactional failure handling", () => {
		const start = readFileSync(PLAN_START_DOC, "utf8");
		const watch = readFileSync(PLAN_WATCH_DOC, "utf8");
		for (const doc of [start, watch]) {
			expect(doc).toContain("Before any worktree mutation");
			expect(doc).toContain("atomically claim");
			expect(doc).toContain("state-lock");
			expect(doc).toContain("from `waiting` to `spawning`");
			expect(doc).toContain("entry.domain.plan_item.pr_number !== null");
			expect(doc).toContain("entry.domain.plan_item.merge_commit !== null");
			expect(doc).toContain("live pane is already registered");
			expect(doc).toContain("state=\"failed\"");
			expect(doc).toContain("domain.plan_item.error = {phase");
		}
		expect(start).toContain("A single item failure does not halt the rest of `plan start`");
		expect(start).toContain("Continue to the next dependency-free item");
		expect(watch).toContain("continue to the next unblocked item");
	});

	test("plan watch handles gh pr create failure and missing PR URL", () => {
		const doc = readFileSync(PLAN_WATCH_DOC, "utf8");
		expect(doc).toContain("`gh pr view`, `gh pr edit`, `gh pr create`");
		expect(doc).toContain('reason:"plan-pr-create-failed"');
		expect(doc).toContain("child completed without PR URL");
	});
});
