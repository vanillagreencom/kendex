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
const LINEAR_CLOSE_DOC = resolve(HERE, "../../../../workflows/linear/close-issue.md");
const LINEAR_MERGE_DOC = resolve(HERE, "../../../../workflows/linear/merge-plan.md");
const PLAN_START_DOC = resolve(HERE, "../../../../workflows/plan/start.md");
const PLAN_HANDLE_DOC = resolve(HERE, "../../../../workflows/plan/handle-prompt.md");
const PLAN_CLOSE_DOC = resolve(HERE, "../../../../workflows/plan/close-item.md");
const PLAN_WATCH_DOC = resolve(HERE, "../../../../workflows/plan/watch.md");
const PLAN_TERMINATE_DOC = resolve(HERE, "../../../../workflows/plan/terminate.md");
const PLAN_FILE_DOC = resolve(HERE, "../../../../PLAN-FILE.md");
const SCHEMA_DOC = resolve(HERE, "../../../../SCHEMA.md");
const PLAN_FILE_FIXTURES = resolve(HERE, "../fixtures/plan-files");
const ACTUAL_PHASE_STYLE_PLAN = resolve(HERE, "../../../../../../docs/plans/flightdeck-app-run-history-and-pi-status-plan.md");

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

function planFixture(file: string): string {
	return readFileSync(join(PLAN_FILE_FIXTURES, file), "utf8");
}

function expectTextBefore(haystack: string, before: string, after: string): void {
	const beforeIndex = haystack.indexOf(before);
	const afterIndex = haystack.indexOf(after);
	expect(beforeIndex).toBeGreaterThanOrEqual(0);
	expect(afterIndex).toBeGreaterThanOrEqual(0);
	expect(beforeIndex).toBeLessThan(afterIndex);
}

function expectTextBeforeLast(haystack: string, before: string, after: string): void {
	const beforeIndex = haystack.indexOf(before);
	const afterIndex = haystack.lastIndexOf(after);
	expect(beforeIndex).toBeGreaterThanOrEqual(0);
	expect(afterIndex).toBeGreaterThanOrEqual(0);
	expect(beforeIndex).toBeLessThan(afterIndex);
}

const SAFE_SHARED_H2 = new Set([
	"pre-execution context",
	"context",
	"background",
	"summary",
	"problem",
	"goals",
	"non-goals",
	"scope",
	"constraints",
	"current state",
	"proposed model",
	"design",
	"architecture",
	"lifecycle changes",
	"dashboard ux",
	"pi extension scope after the rust app",
	"cli/script changes",
	"data model additions",
	"storage layout",
	"acceptance criteria",
	"validation plan",
	"test plan",
	"tests",
	"execution workflow",
	"risks",
	"notes",
	"open questions",
]);

const ORCHESTRATION_ONLY_PATTERNS = [
	/BACKUP-WAKE/i,
	/reviewer fan-out|5-reviewer/i,
	/Do NOT act as Flightdeck master/i,
	/\/skill:flightdeck\s+plan\b/i,
	/\$flightdeck\s+plan\b/i,
	/\/flightdeck\s+plan\b/i,
	/\bflightdeck\s+plan\s+(?:start|watch|close-item|terminate)\b/i,
	/\bflightdeck\s+(?:linear|github)\s+start\b/i,
	/\bflightdeck\s+session\b/i,
];

type ParsedPlanOutcome = {
	mode: "h2-items" | "phase-style" | "ambiguous";
	reason?: string;
	beforePreview: boolean;
	beforeMutation: boolean;
	items: Array<{ id: string; title: string; brief: string; worktree: string; depends_on: string[] }>;
	omittedOrchestrationContext: string[];
	allH2Ids: string[];
};

type H4Section = { title: string; body: string };
type H3Section = { title: string; body: string; intro: string; h4s: H4Section[] };
type H2Section = { title: string; body: string; intro: string; h3s: H3Section[] };

function normalizeHeading(title: string): string {
	return title.replace(/[—–]/g, "-").replace(/\s+/g, " ").trim().toLowerCase();
}

function slugTitle(title: string): string {
	return normalizeHeading(title)
		.replace(/[^a-z0-9]+/g, "-")
		.replace(/-+/g, "-")
		.replace(/^-|-$/g, "")
		.slice(0, 32)
		.replace(/-+$/g, "");
}

function isRecognizedWorkstream(title: string): boolean {
	const normalized = normalizeHeading(title);
	return normalized === "implementation phases" ||
		normalized === "implementation plan" ||
		normalized === "work items" ||
		normalized === "workstreams" ||
		normalized === "execution plan" ||
		normalized.startsWith("additional workstream") ||
		normalized.includes("workstream");
}

function isSafeSharedH2(title: string): boolean {
	const normalized = normalizeHeading(title).replace(/\s*\([^)]*\)\s*$/, "");
	return SAFE_SHARED_H2.has(normalized);
}

function isPhaseItemHeading(title: string): boolean {
	return /^phase\s+\d+(?:\.\d+)?\b/i.test(title) || /^work item\b/i.test(title);
}

function containsOrchestrationOnlyMarker(text: string): boolean {
	return ORCHESTRATION_ONLY_PATTERNS.some((pattern) => pattern.test(text));
}

function parseH2Sections(markdown: string): H2Section[] {
	const lines = markdown.split(/\r?\n/);
	const h2s: Array<{ title: string; line: number }> = [];
	for (let i = 0; i < lines.length; i++) {
		const match = /^##(?!#)\s+(.+?)\s*$/.exec(lines[i] ?? "");
		if (match) h2s.push({ title: match[1], line: i });
	}

	return h2s.map((h2, index) => {
		const end = h2s[index + 1]?.line ?? lines.length;
		const bodyLines = lines.slice(h2.line + 1, end);
		const h3Matches: Array<{ title: string; line: number }> = [];
		for (let i = 0; i < bodyLines.length; i++) {
			const match = /^###(?!#)\s+(.+?)\s*$/.exec(bodyLines[i] ?? "");
			if (match) h3Matches.push({ title: match[1], line: i });
		}
		const intro = bodyLines.slice(0, h3Matches[0]?.line ?? bodyLines.length).join("\n").trim();
		const h3s = h3Matches.map((h3, h3Index) => {
			const h3End = h3Matches[h3Index + 1]?.line ?? bodyLines.length;
			const h3BodyLines = bodyLines.slice(h3.line + 1, h3End);
			const h4Matches: Array<{ title: string; line: number }> = [];
			for (let i = 0; i < h3BodyLines.length; i++) {
				const match = /^####(?!#)\s+(.+?)\s*$/.exec(h3BodyLines[i] ?? "");
				if (match) h4Matches.push({ title: match[1], line: i });
			}
			const h4s = h4Matches.map((h4, h4Index) => {
				const h4End = h4Matches[h4Index + 1]?.line ?? h3BodyLines.length;
				return { title: h4.title, body: h3BodyLines.slice(h4.line + 1, h4End).join("\n").trim() };
			});
			return {
				title: h3.title,
				body: h3BodyLines.join("\n").trim(),
				intro: h3BodyLines.slice(0, h4Matches[0]?.line ?? h3BodyLines.length).join("\n").trim(),
				h4s,
			};
		});
		return { title: h2.title, body: bodyLines.join("\n").trim(), intro, h3s };
	});
}

function parseDepends(body: string): string[] {
	return body
		.split(/[\n,]/)
		.map((line) => line.trim())
		.filter(Boolean)
		.map((title) => slugTitle(title));
}

function itemBriefAndControls(h3: H3Section, itemId: string): { brief: string; worktree: string; depends_on: string[] } {
	const briefParts: string[] = [];
	let worktree = `flightdeck-plan-${itemId}`;
	let depends_on: string[] = [];
	if (h3.intro) briefParts.push(h3.intro);
	for (const h4 of h3.h4s) {
		const normalized = normalizeHeading(h4.title);
		if (normalized === "worktree") {
			worktree = h4.body.split(/\r?\n/).map((line) => line.trim()).find(Boolean) ?? worktree;
			continue;
		}
		if (normalized === "depends on") {
			depends_on = parseDepends(h4.body);
			continue;
		}
		briefParts.push(`#### ${h4.title}\n\n${h4.body}`);
	}
	return { brief: briefParts.join("\n\n"), depends_on, worktree };
}

function ambiguous(reason: string): ParsedPlanOutcome {
	return { mode: "ambiguous", reason, beforePreview: true, beforeMutation: true, items: [], omittedOrchestrationContext: [], allH2Ids: [] };
}

function parsePlanContract(markdown: string): ParsedPlanOutcome {
	const h2s = parseH2Sections(markdown);
	const allH2Ids = h2s.map((section) => slugTitle(section.title));
	const hasPhaseIndicators = h2s.some((section) => section.h3s.some((h3) => isPhaseItemHeading(h3.title)));
	const hasRecognizedPhaseItems = h2s.some((section) => isRecognizedWorkstream(section.title) && section.h3s.some((h3) => isPhaseItemHeading(h3.title)));

	if (hasPhaseIndicators && !hasRecognizedPhaseItems) {
		return { ...ambiguous("plan-format-ambiguous: ambiguous plan format; use either H2 item mode or put Phase/Work item H3s under an implementation workstream"), allH2Ids };
	}

	if (!hasPhaseIndicators) {
		return {
			mode: "h2-items",
			beforePreview: false,
			beforeMutation: true,
			items: h2s.map((section) => ({ id: slugTitle(section.title), title: section.title, brief: section.body, worktree: `flightdeck-plan-${slugTitle(section.title)}`, depends_on: [] })),
			omittedOrchestrationContext: [],
			allH2Ids,
		};
	}

	const safeGlobalContext: string[] = [];
	const omittedOrchestrationContext: string[] = [];
	for (const section of h2s) {
		if (isRecognizedWorkstream(section.title)) continue;
		if (!isSafeSharedH2(section.title)) {
			return { ...ambiguous(`plan-format-ambiguous: H2 '${section.title}' is neither an implementation workstream nor allowlisted shared context`), allH2Ids };
		}
		if (containsOrchestrationOnlyMarker(section.body)) {
			omittedOrchestrationContext.push(section.title);
		} else {
			safeGlobalContext.push(`## ${section.title}\n\n${section.body}`);
		}
	}

	const items: ParsedPlanOutcome["items"] = [];
	for (const section of h2s.filter((candidate) => isRecognizedWorkstream(candidate.title))) {
		const safeLocalContext: string[] = [];
		if (section.intro) {
			if (containsOrchestrationOnlyMarker(section.intro)) omittedOrchestrationContext.push(section.title);
			else safeLocalContext.push(section.intro);
		}
		for (const h3 of section.h3s) {
			if (isPhaseItemHeading(h3.title)) continue;
			if (containsOrchestrationOnlyMarker(h3.body)) omittedOrchestrationContext.push(`${section.title} / ${h3.title}`);
			else safeLocalContext.push(`### ${h3.title}\n\n${h3.body}`);
		}
		for (const h3 of section.h3s.filter((candidate) => isPhaseItemHeading(candidate.title))) {
			const id = slugTitle(h3.title);
			if (containsOrchestrationOnlyMarker(h3.body)) {
				return { ...ambiguous(`plan-format-ambiguous: ${id} contains Flightdeck master-only orchestration instructions`), allH2Ids };
			}
			const controls = itemBriefAndControls(h3, id);
			items.push({ id, title: h3.title, brief: [...safeGlobalContext, ...safeLocalContext, controls.brief].filter(Boolean).join("\n\n---\n\n"), worktree: controls.worktree, depends_on: controls.depends_on });
		}
	}

	return { mode: "phase-style", beforePreview: false, beforeMutation: true, items, omittedOrchestrationContext, allH2Ids };
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
		expectTextBeforeLast(doc, "gh pr view <PR> --json state,mergeStateStatus,mergeCommit", "gh issue close <N> --reason completed");
	});


	test("generic terminal handler stays domain-neutral and does not sync repos", () => {
		const doc = readFileSync(HANDLER_DOC, "utf8");
		expect(doc).toContain("Do not query GitHub, infer PR state, or run repository sync from the generic lane");
		expect(doc).not.toContain("flightdeck-repo-sync main");
	});

	test("github close post-merge repo sync requires authoritative MERGED state", () => {
		const doc = readFileSync(GITHUB_CLOSE_DOC, "utf8");
		expect(doc).toContain("flightdeck-repo-sync main --project-root <PROJECT_ROOT> --remote origin --branch main --json");
		expect(doc).toContain("gh pr view <PR> --json state,mergeStateStatus,mergeCommit");
		expect(doc).toContain('state === "MERGED"');
		expect(doc).toContain("mergeCommit !== null");
		expect(doc).toContain("Do not run this helper for queued auto-merge");
		expect(doc).toContain("repo.main_sync_blocked");
	});

	test("plan close post-merge repo sync requires authoritative MERGED state", () => {
		const doc = readFileSync(PLAN_CLOSE_DOC, "utf8");
		expect(doc).toContain("flightdeck-repo-sync main --project-root <PROJECT_ROOT> --remote origin --branch main --json");
		expect(doc).toContain("gh pr view <PR> --json state,mergeStateStatus,mergeCommit");
		expect(doc).toContain('state === "MERGED"');
		expect(doc).toContain("mergeCommit !== null");
		expect(doc).toContain("Do not run this helper for queued auto-merge");
		expect(doc).toContain("repo.main_sync_failed");
	});

	test("linear close post-merge repo sync is not driven by pane text", () => {
		const doc = readFileSync(LINEAR_CLOSE_DOC, "utf8");
		const proof = doc.indexOf("gh pr view <PR> --json state,mergeStateStatus,mergeCommit");
		const setState = doc.indexOf("pane-registry set-state <ISSUE_ID> <merged|aborted>");
		const persistFields = doc.indexOf("Persist any captured summary fields");
		const teardown = doc.indexOf("pane-registry teardown-window <ISSUE_ID>");
		expect(doc).toContain("flightdeck-repo-sync main --project-root <PROJECT_ROOT> --remote origin --branch main --json");
		expect(doc).toContain("gh pr view <PR> --json state,mergeStateStatus,mergeCommit");
		expect(doc).toContain('state === "MERGED"');
		expect(doc).toContain("mergeCommit !== null");
		expect(doc).toContain("If the `merged` outcome came only from pane text");
		expect(doc).toContain("Leave the entry non-terminal and return to the watch loop");
		expect(doc).toContain("proceed to § 2 with candidate `state = merged`");
		expect(doc).toContain("This fast-path only satisfies signal counting");
		expect(doc).not.toContain("proceed directly to § 3 with `state = merged`");
		expect(doc).toContain("Do not run this helper for queued auto-merge");
		expect(proof).toBeGreaterThanOrEqual(0);
		expect(setState).toBeGreaterThanOrEqual(0);
		expect(persistFields).toBeGreaterThanOrEqual(0);
		expect(teardown).toBeGreaterThanOrEqual(0);
		expect(proof).toBeLessThan(setState);
		expect(proof).toBeLessThan(persistFields);
		expect(proof).toBeLessThan(teardown);
	});

	test("linear direct merge sync skips queued auto-merge", () => {
		const doc = readFileSync(LINEAR_MERGE_DOC, "utf8");
		const proof = doc.indexOf("gh pr view <PR> --json state,mergeStateStatus,mergeCommit");
		expect(doc).toContain("flightdeck-repo-sync main --project-root <PROJECT_ROOT> --remote origin --branch main --json");
		expect(doc).toContain("The `pr-merge` exit code is not proof by itself");
		expect(doc).toContain('state === "MERGED"');
		expect(doc).toContain("mergeCommit !== null");
		expect(doc).toContain("do **not** call `pane-registry set-state`, persist `merge_commit`, run repo sync, recompute the graph, or perform terminal handling");
		expect(doc).toContain("This step only runs after exit `0` plus authoritative");
		expect(doc).toContain("It does not run for exit `75` queued auto-merge");
		expect(doc).toContain("repo.main_synced");
		expectTextBefore(doc, "gh pr view <PR> --json state,mergeStateStatus,mergeCommit", "pane-registry set-state <ISSUE_ID> merged");
		expectTextBefore(doc, "gh pr view <PR> --json state,mergeStateStatus,mergeCommit", "pane-registry set <ISSUE_ID> merge_commit <mergeCommit.oid>");
		expectTextBefore(doc, "gh pr view <PR> --json state,mergeStateStatus,mergeCommit", "flightdeck-repo-sync main --project-root <PROJECT_ROOT> --remote origin --branch main --json");
		expect(proof).toBeGreaterThanOrEqual(0);
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
		const spawnPrompts = combined.match(/--prompt "[^"]*"/g) ?? [];
		expect(combined).toContain("flightdeck-session start");
		expect(combined).toContain("--kind workflow");
		expect(combined).toContain("Read tmp/brief.md and execute end-to-end. Print the PR URL as the LAST line.");
		expect(spawnPrompts.length).toBeGreaterThan(0);
		expect(spawnPrompts.join("\n")).not.toMatch(/\/skill:flightdeck plan|\$flightdeck plan|\/flightdeck plan (start|watch|close|terminate)/);
		expect(spawnPrompts.join("\n")).not.toContain("/skill:");
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
		expectTextBefore(doc, "Validate the parse mode and plan graph before dry-run preview", "<parse_preview_format>");
		expect(doc).toContain('reason:"plan-parse-invalid"');
		expect(doc).toContain('prompt_text:"<ABSOLUTE_PLAN_PATH>: zero work items"');
		expect(doc).toContain('reason:"plan-dependency-unresolved"');
		expect(doc).toContain("depends on '<BAD_NAME>' which doesn't match any item title or id");
		expect(doc).toContain('reason:"plan-self-dependency"');
		expect(doc).toContain('prompt_text:"<ITEM_ID> depends on itself"');
		expect(doc).toContain('reason:"plan-dependency-cycle"');
		expect(doc).toContain('prompt_text:"cycle: <ITEM_A> -> <ITEM_B> -> <ITEM_A>"');
	});

	test("plan lane supports phase-style docs without treating context H2s as items", () => {
		const start = readFileSync(PLAN_START_DOC, "utf8");
		const watch = readFileSync(PLAN_WATCH_DOC, "utf8");
		const handle = readFileSync(PLAN_HANDLE_DOC, "utf8");
		const planFile = readFileSync(PLAN_FILE_DOC, "utf8");
		const schema = readFileSync(SCHEMA_DOC, "utf8");
		for (const doc of [start, planFile]) {
			expect(doc).toContain("phase-style");
			expect(doc).toContain("Implementation phases");
			expect(doc).toContain("### Phase");
			expect(doc).toContain("shared context");
		}
		expect(start).toContain("A malformed phase-style file must not fall back to H2 item mode");
		expect(start).toContain("Any other H2 outside a recognized implementation workstream is ambiguous; do not silently treat it as shared context");
		expect(start).toContain("H2 '<H2_TITLE>' is neither an implementation workstream nor allowlisted shared context");
		expect(start).toContain("Additional workstream");
		expect(start).toContain("Non-item H3s inside a workstream, such as `### Context`, `### Summary`, `### Goals`, and `### Non-goals`, are workstream-local shared context, not items");
		expect(start).toContain("Context-only H2 sections outside the safe allowlist must never appear as preview Item rows");
		expect(start).toContain("Omit matching shared-context sections from child briefs and show their titles in the preview as omitted orchestration context");
		expect(start).toContain("<ITEM_ID> contains Flightdeck master-only orchestration instructions");
		expect(start).toContain("brief_artifact_path");
		expect(start).toContain("brief_sha256");
		expect(start).toContain("plan_snapshot_sha256");
		expect(start).toContain("Plan watch and dependency-edge resolution must consume only these immutable brief artifacts");
		expect(start).toContain("They must not reread mutable `plan_path` to rebuild child briefs after compaction/re-entry");
		expect(watch).toContain("Do not reread `domain.plan_item.plan_path` to rebuild child briefs");
		expect(watch).toContain("Treat `domain.plan_item.plan_path` as traceability only after plan start");
		expect(watch).not.toContain('reason="plan-file-missing"');
		expect(watch).toContain("The artifact hash matches `domain.plan_item.brief_sha256`");
		expect(handle).toContain("Do not reread `domain.plan_item.plan_path` to rebuild child briefs");
		expect(handle).toContain("Require `domain.plan_item.brief_artifact_path`, `domain.plan_item.brief_sha256`, and `domain.plan_item.plan_snapshot_sha256`");
		expect(schema).toContain("brief_artifact_path");
		expect(schema).toContain("brief_sha256");
		expect(schema).toContain("plan_snapshot_sha256");
		expect(start).toContain('reason:"plan-format-ambiguous"');
		expect(start).toContain("Mode: [PARSE_MODE]");
		expect(start).toContain("Shared context: [global H2/workstream-local titles or —]");
		expect(start).toContain("Omitted orchestration context: [titles or —]");
		expect(planFile).toContain("Preview must show only `phase-1-normalize-error-payloads`, `phase-2-render-diagnostics`, and `phase-3-update-troubleshooting-guide` as items");
		expect(planFile).toContain("`Problem`, `Goals`, `Additional workstream — Documentation follow-ups`, and `Context` are shared context, not work items");
		expect(planFile).toContain("Malformed phase-style sections do not fall back to H2 item mode");
		expect(planFile).toContain("Result: `plan-format-ambiguous`");
	});

	test("actual app/run-history plan remains valid phase-style under the allowlist", () => {
		const parsed = parsePlanContract(readFileSync(ACTUAL_PHASE_STYLE_PLAN, "utf8"));
		expect(parsed.mode).toBe("phase-style");
		expect(parsed.reason).toBeUndefined();
		expect(parsed.items.map((item) => item.title)).toContain("Phase 1 — Design and compatibility layer");
		expect(parsed.items.map((item) => item.title)).toContain("Phase 6.7 — App focus/open helper, icon title, and launch order");
		expect(parsed.items.map((item) => item.title)).toContain("Phase 12 — No-op confirmations for upstream-only fixes");
		for (const requiredSafeH2 of ["pi-extension-scope-after-the-rus", "cli-script-changes", "data-model-additions"]) {
			expect(parsed.allH2Ids).toContain(requiredSafeH2);
			expect(parsed.items.map((item) => item.id)).not.toContain(requiredSafeH2);
		}
		expect(parsed.items.length).toBe(15);
	});

	test("phase-style fixture parses exact phase items and excludes context-only H2s", () => {
		const parsed = parsePlanContract(planFixture("phase-style-valid.md"));
		expect(parsed.mode).toBe("phase-style");
		expect(parsed.beforeMutation).toBe(true);
		expect(parsed.items.map((item) => item.id)).toEqual([
			"phase-1-run-identity",
			"phase-2-state-command-support",
			"phase-8-codex-provider-shim",
			"phase-9-responsive-skills-rows",
		]);
		expect(parsed.items[0]).toMatchObject({
			depends_on: [],
			worktree: "flightdeck-plan-run-identity",
		});
		expect(parsed.items[1]).toMatchObject({
			depends_on: ["phase-1-run-identity"],
			worktree: "flightdeck-plan-phase-2-state-command-support",
		});
		for (const contextH2 of [
			"pre-execution-context-updated-20",
			"problem",
			"goals",
			"lifecycle-changes",
			"implementation-phases",
			"additional-workstream-pi-followu",
			"acceptance-criteria",
			"validation-plan",
			"execution-workflow",
		]) {
			expect(parsed.allH2Ids).toContain(contextH2);
			expect(parsed.items.map((item) => item.id)).not.toContain(contextH2);
		}
		expect(parsed.omittedOrchestrationContext).toEqual(["Pre-execution context (updated 2026-05-19)", "Execution workflow"]);
		for (const brief of parsed.items.map((item) => item.brief)) {
			expect(brief).toContain("Flightdeck needs clearer run identity and history behavior");
			expect(brief).not.toContain("#### Worktree");
			expect(brief).not.toContain("#### Depends on");
			expect(brief).not.toContain("flightdeck-plan-run-identity");
			expect(brief).not.toContain("Phase 1 — Run identity");
			expect(brief).not.toMatch(/BACKUP-WAKE|5-reviewer|Do NOT act as Flightdeck master|\/skill:flightdeck\s+plan|\/flightdeck\s+plan|\bflightdeck\s+plan\s+(?:start|watch|close-item|terminate)\b/i);
		}
	});

	test("malformed or mixed phase-style fixtures fail closed before preview or mutation", () => {
		const malformed = parsePlanContract(planFixture("malformed-phases-h2.md"));
		expect(malformed.mode).toBe("ambiguous");
		expect(malformed.reason).toContain("plan-format-ambiguous");
		expect(malformed.reason).toContain("put Phase/Work item H3s under an implementation workstream");
		expect(malformed.beforePreview).toBe(true);
		expect(malformed.beforeMutation).toBe(true);
		expect(malformed.items).toEqual([]);

		const mixed = parsePlanContract(planFixture("mixed-unknown-h2.md"));
		expect(mixed.mode).toBe("ambiguous");
		expect(mixed.reason).toContain("plan-format-ambiguous");
		expect(mixed.reason).toContain("Refactor dashboard");
		expect(mixed.reason).toContain("neither an implementation workstream nor allowlisted shared context");
		expect(mixed.beforePreview).toBe(true);
		expect(mixed.beforeMutation).toBe(true);
		expect(mixed.items).toEqual([]);
	});

	test("implementation item content with Flightdeck master commands fails instead of entering child briefs", () => {
		const parsed = parsePlanContract(planFixture("item-master-command.md"));
		expect(parsed.mode).toBe("ambiguous");
		expect(parsed.reason).toContain("plan-format-ambiguous");
		expect(parsed.reason).toContain("phase-1-parser-guard contains Flightdeck master-only orchestration instructions");
		expect(parsed.beforePreview).toBe(true);
		expect(parsed.beforeMutation).toBe(true);
		expect(parsed.items).toEqual([]);
	});

	test("plan spawn docs require atomic claim and transactional failure handling", () => {
		const start = readFileSync(PLAN_START_DOC, "utf8");
		const watch = readFileSync(PLAN_WATCH_DOC, "utf8");
		const handle = readFileSync(PLAN_HANDLE_DOC, "utf8");
		for (const doc of [start, watch, handle]) {
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
		expect(handle).toContain("continue to the next unblocked item");
	});

	test("plan watch handles gh pr create failure and missing PR URL", () => {
		const doc = readFileSync(PLAN_WATCH_DOC, "utf8");
		expect(doc).toContain("`gh pr view`, `gh pr edit`, `gh pr create`");
		expect(doc).toContain('reason:"plan-pr-create-failed"');
		expect(doc).toContain("child completed without PR URL");
	});
});
