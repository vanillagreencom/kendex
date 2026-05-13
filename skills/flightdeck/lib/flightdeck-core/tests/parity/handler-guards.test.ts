import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ISSUE_ONLY_TAGS } from "../../src/classifier/rules.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURES = resolve(HERE, "../fixtures/prompt-classify");
const BASH_SCRIPT = resolve(HERE, "../../../../scripts/prompt-classify.bash");
const TS_SCRIPT = resolve(HERE, "../../src/bin/prompt-classify.ts");

const GENERIC_PROMPT = `Choose the next action.

1. Continue
2. Ask for help

Enter to select
`;

// Planned review terms map to current canonical tags as follows:
// - merge-ready / merge-prompt: merge-now, merge-ready-but-unknown, force-merge-confirm
// - cleanup-worktree: cleanup-prompt
// - bot-review: bot-review-wait-stuck
// - rebase: rebase-multi-choice
// - review-fix: external-fix-suggestions and cycle-fix-suggestions
// - scope-creep: scope-creep-detected is computed outside prompt-classify, so
//   it is asserted in the guard sets below rather than via a buffer fixture.
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

function runBash(input: string, args: string[] = []): { stdout: string; stderr: string; status: number | null } {
	const r = spawnSync(BASH_SCRIPT, args, { encoding: "utf8", input });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function runTs(input: string, args: string[] = []): { stdout: string; stderr: string; status: number | null } {
	const r = spawnSync("bun", ["run", TS_SCRIPT, ...args], { encoding: "utf8", input });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function runBoth(input: string, args: string[] = []): { bash: ReturnType<typeof runBash>; ts: ReturnType<typeof runTs> } {
	return { bash: runBash(input, args), ts: runTs(input, args) };
}

function expectBoth(input: string, args: string[], expected: string): ReturnType<typeof runBoth> {
	const result = runBoth(input, args);
	expect(result.bash.status).toBe(0);
	expect(result.ts.status).toBe(0);
	expect(result.ts.stdout.trim()).toBe(result.bash.stdout.trim());
	expect(result.ts.stdout.trim()).toBe(expected);
	return result;
}

function expectWarning(result: ReturnType<typeof runBoth>, expected: string): void {
	expect(result.bash.stderr).toContain(expected);
	expect(result.ts.stderr).toContain(expected);
}

describe("handler domain guards", () => {
	for (const { tag, fixture: fixtureName } of ISSUE_ONLY_CASES) {
		test(`${tag} on adhoc escalates, on issue routes normally`, () => {
			const input = fixture(fixtureName);
			const adhoc = expectBoth(input, ["--entry-kind", "adhoc"], "domain-mismatch");
			expectWarning(adhoc, `issue-only prompt tag ${tag}`);

			const issue = expectBoth(input, ["--entry-kind", "issue"], tag);
			expect(issue.bash.stderr).toBe("");
			expect(issue.ts.stderr).toBe("");
		});
	}

	test("entry kind unknown sentinel escalates issue-only prompt as domain-mismatch", () => {
		const result = expectBoth(fixture("14-merge-now.buffer"), ["--entry-kind-unknown"], "domain-mismatch");
		expectWarning(result, "issue-only prompt tag merge-now");
	});

	test("missing entry kind fails closed by default", () => {
		const result = expectBoth(fixture("14-merge-now.buffer"), [], "domain-mismatch");
		expectWarning(result, "classified without --entry-kind");
		expectWarning(result, "routing as domain-mismatch");
	});

	test("legacy caller with allow-missing-kind warns but remains permissive", () => {
		const result = expectBoth(fixture("14-merge-now.buffer"), ["--allow-missing-kind"], "merge-now");
		expectWarning(result, "--allow-missing-kind was set");
		expectWarning(result, "Migrate to --entry-kind issue");
	});

	test("generic tag on issue entry remains generic for the generic handler", () => {
		expectBoth(GENERIC_PROMPT, ["--entry-kind", "issue"], "generic-multi-choice");
	});

	test("computed issue-only tags are present in both guard sets", () => {
		expect(ISSUE_ONLY_TAGS.has("scope-creep-detected")).toBe(true);
		const bashSource = readFileSync(BASH_SCRIPT, "utf8");
		expect(bashSource).toContain("scope-creep-detected");
	});
});
