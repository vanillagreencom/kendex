import { expect, test } from "bun:test";
import { complete } from "../extensions/qol/pi-ai-compat.ts";

test("complete falls back to the pi-ai compat entrypoint", async () => {
	const result = await complete({}, {}, { signal: "sentinel" }, {
		root: {},
		loadCompat: async () => ({
			complete: async (_model: unknown, _context: unknown, options: unknown) => ({ options }),
		}),
	});
	expect(result.options).toEqual({ signal: "sentinel" });
});

test("complete prefers the legacy root export", async () => {
	const result = await complete("model", "context", "options", {
		root: { complete: async (...args: unknown[]) => args },
		loadCompat: async () => { throw new Error("compat should not load"); },
	});
	expect(result).toEqual(["model", "context", "options"]);
});