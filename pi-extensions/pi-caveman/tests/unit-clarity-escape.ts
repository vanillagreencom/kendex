import { test } from "node:test";
import assert from "node:assert/strict";
import { shouldClarityEscape } from "../extensions/prompt.ts";

	const shouldMatch = [
		"this would force-push and rewrite history",
		"DROP TABLE users",
		"rm -rf the build dir",
		"git reset --hard origin/main",
		"git push --force origin main",
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
	];
for (const row of [
	...shouldMatch.map((phrase) => ({ phrase, expected: true })),
	...shouldNotMatch.map((phrase) => ({ phrase, expected: false })),
]) {
	test(`clarity escape ${row.expected}: ${row.phrase}`, () => {
		assert.equal(shouldClarityEscape(row.phrase), row.expected);
	});
}
