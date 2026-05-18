import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ISSUE_ONLY_TAGS } from "../../src/classifier/rules.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURES = resolve(HERE, "../fixtures/prompt-classify");
const TS_SCRIPT = resolve(HERE, "../../src/bin/prompt-classify.ts");
const HANDLER_DOC = resolve(HERE, "../../../../workflows/session-handle-prompt.md");

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
});
