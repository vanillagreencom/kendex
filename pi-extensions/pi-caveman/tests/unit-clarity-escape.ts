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
	];
for (const row of [
	...shouldMatch.map((phrase) => ({ phrase, expected: true })),
	...shouldNotMatch.map((phrase) => ({ phrase, expected: false })),
]) {
	test(`clarity escape ${row.expected}: ${row.phrase}`, () => {
		assert.equal(shouldClarityEscape(row.phrase), row.expected);
	});
}

// Measured, not waited on: a backtracking pattern takes hundreds of
// milliseconds on these prompts, and a linear scan takes well under one.
for (const [name, prompt] of [
	["whitespace run after git push", "git push" + " ".repeat(32768)],
	["repeated git push on one line", "git push x ".repeat(3640) + "\nthen --force"],
]) {
	test(`clarity escape stays linear: ${name}`, () => {
		const started = performance.now();
		assert.equal(shouldClarityEscape(prompt), false);
		const elapsed = performance.now() - started;
		assert.ok(elapsed < 5, `took ${elapsed.toFixed(1)} ms`);
	});
}
