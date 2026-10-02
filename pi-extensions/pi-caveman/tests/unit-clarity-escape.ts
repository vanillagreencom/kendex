import { performance } from "node:perf_hooks";
import { test } from "node:test";
import assert from "node:assert/strict";
import { shouldClarityEscape } from "../extensions/prompt.ts";

	const shouldMatch = [
		"this would force-push and rewrite history",
		"DROP TABLE users",
		"rm -rf the build dir",
		"git reset --hard origin/main",
		"git push --force origin main",
		"git push origin main --force",
		"git  push \n  origin --force",
		"git push origin\n--force",
		"git push a\ngit push --force",
		"that's a destructive operation",
		"this is an irreversible migration",
	];
	// User prompts that contain soft signals must stay quiet.
	const shouldNotMatch = [
		"refactor the parser to use the new API",
		"add a unit test for the queue",
		"format the table output",
		"please confirm the version bumped",
		"delete the old log entries",
		"please review for security vulnerabilities",
		"is this a credential exposure?",
		"can you clarify the trade-off",
		"I'm confused about the data flow",
		"the spec is ambiguous",
		"Can you explain to me more about what 507 is about? We dont need to measure performance on non consumer surfaces (dev dashboard, etc.) so i'm confused by 1) what this issue is and 2) what the questions are about",
		"I want to audit our code, benchmarking, performance checks, etc. for anything that is unneccisarily measuring non consumer surfaces specifically.",
		"What is --secondary-window about? At some point we will have real secondary windows that are consumer surfaces (for example a chart extracted into its own window) - so does that framing change anything?",
		"Yes.",
		"git push origin main\nthen run it with --force",
		"git push origin main --dry-run",
		"git push a\nb --force\ngit push c",
	];
for (const row of [
	...shouldMatch.map((phrase) => ({ phrase, expected: true })),
	...shouldNotMatch.map((phrase) => ({ phrase, expected: false })),
]) {
	test(`clarity escape ${row.expected}: ${row.phrase}`, () => {
		assert.equal(shouldClarityEscape(row.phrase), row.expected);
	});
}

// The defect is time spent on submit, so these rows read the real clock. On
// these prompts the scan took under 10 ms warm and under 30 ms on a cold first
// call. The old backtracking pattern took about 1 s on the whitespace run and
// minutes on the repeated commands. A scan that recomputes the next --force per
// command took about 7.6 s on the repeated commands, and one that recomputes the
// line end took about 1 s. The bound sits between the scan and those, with
// headroom for a loaded runner.
const LINEAR_BOUND_MS = 200;
for (const [name, prompt] of [
	["whitespace run after git push", "git push" + " ".repeat(32768)],
	["repeated git push on one line", "git push x ".repeat(131072) + "\nthen --force"],
]) {
	test(`clarity escape stays linear: ${name}`, () => {
		const started = performance.now();
		assert.equal(shouldClarityEscape(prompt), false);
		const elapsed = performance.now() - started;
		assert.ok(elapsed < LINEAR_BOUND_MS, `took ${elapsed.toFixed(1)} ms`);
	});
}
