import assert from "node:assert/strict";
import test, { after } from "node:test";
import { assertStoppedConsumers } from "./extension-fixture.js";
import { cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";

after(cleanupTempRuntimes);

for (const [surface, before, replacement] of [
	["finished-turn wait", 'isTaskTurnFinished(record.status)', 'false && isTaskTurnFinished(record.status)'],
	["result presentation", 'taskStatus(details?.status).tone', '"error"'],
] as const) test(`control: result lookup bypasses the ${surface} owner`, async () => {
	const support = await importRuntimeCopy("pane-support-tools.ts", before, replacement) as typeof import("../extensions/subagent/pane-support-tools.js");
	const key = Symbol.for("test.pane-support-tools");
	const globals = globalThis as unknown as Record<symbol, unknown>;
	globals[key] = support.registerPaneSupportTools;
	try {
		const extension = await importRuntimeCopy("index.ts", 'import { registerPaneSupportTools } from "./pane-support-tools.js";', 'const registerPaneSupportTools = globalThis[Symbol.for("test.pane-support-tools")];') as typeof import("../extensions/subagent/index.js");
		await assert.rejects(() => assertStoppedConsumers(extension.default), assert.AssertionError);
	} finally { delete globals[key]; }
});
