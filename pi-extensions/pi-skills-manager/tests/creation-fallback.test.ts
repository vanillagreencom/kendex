import assert from "node:assert/strict";
import { test } from "bun:test";
import { resolveSkillDraft } from "../extensions/skills-manager/creation-fallback.ts";

for (const row of [
	{ name: "provider failure returns fallback and forwards the error", kind: "failure", expected: "fallback", generated: 1, fallback: 1, notified: true },
	{ name: "pre-abort bypasses generation and fallback", kind: "pre-abort", expected: null, generated: 0, fallback: 0, notified: false },
	{ name: "AbortError during generation bypasses fallback", kind: "abort-error", expected: null, generated: 1, fallback: 0, notified: false },
] as const) {
	test(row.name, async () => {
		const controller = new AbortController();
		if (row.kind === "pre-abort") controller.abort();
		const error = new Error("fixture failure");
		if (row.kind === "abort-error") error.name = "AbortError";
		const reasons: unknown[] = [];
		let generated = 0;
		let fallbacks = 0;
		const draft = await resolveSkillDraft(
			async () => { generated += 1; throw error; },
			() => { fallbacks += 1; return "fallback"; }, row.kind === "pre-abort" ? controller.signal : undefined,
			(reason) => { reasons.push(reason); },
		);
		assert.equal(draft, row.expected);
		assert.equal(generated, row.generated);
		assert.equal(fallbacks, row.fallback);
		assert.equal(reasons.length, row.notified ? 1 : 0);
		if (row.notified) assert.equal(reasons[0], error);
	});
}
