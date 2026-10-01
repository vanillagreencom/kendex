import assert from "node:assert/strict";
import test, { after } from "node:test";
import { MonitorDetailCache } from "../extensions/subagent/browser/monitor-cache.js";
import { cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";

after(cleanupTempRuntimes);

for (const [name, before, afterText, text, count] of [
	["count", "this.size > 32", "this.size > Infinity", "small", 33],
	["bytes", "bytes > 4 * 1024 * 1024", "bytes > Infinity", "x".repeat(2 * 1024 * 1024), 3],
] as const) {
	test(`monitor traces are bounded by ${name}`, async () => {
		const assertBound = (Cache: typeof MonitorDetailCache) => {
			const cache = new Cache();
			for (let i = 0; i < count; i++) cache.set(String(i), { items: [{ label: "Summary", type: "summary", text }] });
			assert.equal(cache.has("0"), false);
			cache.clear();
			assert.equal(cache.size, 0);
		};
		assertBound(MonitorDetailCache);
		const mutant = await importRuntimeCopy("browser/monitor-cache.ts", before, afterText) as typeof import("../extensions/subagent/browser/monitor-cache.js");
		assert.throws(() => assertBound(mutant.MonitorDetailCache));
	});
}
