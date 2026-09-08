import { expect, mock, test } from "bun:test";

mock.module("@earendil-works/pi-ai", () => ({}));
mock.module("@earendil-works/pi-ai/compat", () => ({
	completeSimple: async (_model: unknown, _context: unknown, options: unknown) => ({
		content: [{ type: "text", text: "generated" }], options,
	}),
}));
const { completeSimple } = await import("../extensions/skills-manager/pi-ai-compat.ts");

for (const row of [
	{
		name: "compat entrypoint fallback", model: {}, context: {}, options: { reasoning: "high" }, deps: {},
		expected: { content: [{ type: "text", text: "generated" }], options: { reasoning: "high" } },
	},
	{
		name: "legacy root export preference", model: "model", context: "context", options: "options",
		deps: {
			root: { completeSimple: async (...args: unknown[]) => args },
			loadCompat: async () => { throw new Error("unexpected compat import"); },
		},
		expected: ["model", "context", "options"],
	},
]) {
	test(row.name, async () => {
		expect(await completeSimple(row.model, row.context, row.options, row.deps)).toEqual(row.expected);
	});
}
