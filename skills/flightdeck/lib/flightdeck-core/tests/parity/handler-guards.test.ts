import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const BASH_SCRIPT = resolve(HERE, "../../../../scripts/prompt-classify.bash");
const TS_SCRIPT = resolve(HERE, "../../src/bin/prompt-classify.ts");

const MERGE_PROMPT = `PR #42 is approved with CI passing. Merge now?

1. Merge PR
2. Wait

Enter to select
`;

const GENERIC_PROMPT = `Choose the next action.

1. Continue
2. Ask for help

Enter to select
`;

function runBash(input: string, args: string[] = []): { stdout: string; stderr: string; status: number | null } {
	const r = spawnSync(BASH_SCRIPT, args, { encoding: "utf8", input });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function runTs(input: string, args: string[] = []): { stdout: string; stderr: string; status: number | null } {
	const r = spawnSync("bun", ["run", TS_SCRIPT, ...args], { encoding: "utf8", input });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function expectBoth(input: string, args: string[], expected: string): void {
	const bash = runBash(input, args);
	const ts = runTs(input, args);
	expect(bash.status).toBe(0);
	expect(ts.status).toBe(0);
	expect(ts.stdout.trim()).toBe(bash.stdout.trim());
	expect(ts.stdout.trim()).toBe(expected);
}

describe("handler domain guards", () => {
	test("issue-only tag on adhoc entry escalates as domain-mismatch", () => {
		expectBoth(MERGE_PROMPT, ["--entry-kind", "adhoc"], "domain-mismatch");
		expect(runBash(MERGE_PROMPT, ["--entry-kind", "adhoc"]).stderr).toContain("issue-only prompt tag merge-now");
		expect(runTs(MERGE_PROMPT, ["--entry-kind", "adhoc"]).stderr).toContain("issue-only prompt tag merge-now");
	});

	test("generic tag on issue entry remains generic for the generic handler", () => {
		expectBoth(GENERIC_PROMPT, ["--entry-kind", "issue"], "generic-multi-choice");
	});

	test("legacy callers without entry kind still receive issue tags", () => {
		expectBoth(MERGE_PROMPT, [], "merge-now");
	});
});
