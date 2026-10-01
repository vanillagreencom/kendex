import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { withExtensionTools } from "./extension-fixture.js";
import { bridgeEvent, bridgeStdout, cleanupTempRuntimes, installMockSpawn } from "./single-agent-fixture.js";
import { importRuntimeCopy } from "./browser-fixture.js";

after(cleanupTempRuntimes);

const rows = [
	{ agent: "", task: "", tasks: [{ agent: "scout", task: "map" }] },
	{ agent: "", task: "", chain: [{ agent: "scout", task: "map" }] },
	{ agent: "scout", task: "map", tasks: [{ agent: "", task: "" }], chain: [{ agent: "scout", task: "" }] },
	{ agent: "", task: "ignored", tasks: [{ agent: "scout", task: "map" }, { agent: "", task: "ignored" }, { agent: "scout", task: "" }] },
];

for (const params of rows) {
	test(`empty strings are absent: ${JSON.stringify(params)}`, async () => {
		await withExtensionTools(async (tools, ctx, harness) => {
			mkdirSync(join(harness.cwd, ".pi", "agents"), { recursive: true });
			writeFileSync(join(harness.cwd, ".pi", "agents", "scout.md"), "---\nname: scout\ndescription: map\n---\nmap\n");
			const calls = installMockSpawn([{ stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "mapped" }] } })]) }]);
			try {
				const result = await tools.get("subagent").execute("test", params, undefined, undefined, ctx);
				assert.deepEqual([calls.length, result.details.results.map((item: { agent: string }) => item.agent), result.isError ?? false], [1, ["scout"], false]);
			} finally { setSingleAgentSpawnForTests(); }
		});
	});
}

test("control: collecting empty names rejects a valid tasks dispatch", async () => {
	const mutant = await importRuntimeCopy("index.ts", 'const inventoryError = validateAgentInventory(requestedAgentNames,', 'if (typeof params.agent === "string") requestedAgentNames.add(params.agent);\nconst inventoryError = validateAgentInventory(requestedAgentNames,') as typeof import("../extensions/subagent/index.js");
	await withExtensionTools(async (tools, ctx, harness) => {
		mkdirSync(join(harness.cwd, ".pi", "agents"), { recursive: true });
		writeFileSync(join(harness.cwd, ".pi", "agents", "scout.md"), "---\nname: scout\ndescription: map\n---\nmap\n");
		const result = await tools.get("subagent").execute("test", rows[0], undefined, undefined, ctx);
		assert.throws(() => assert.equal(result.isError ?? false, false), assert.AssertionError);
		assert.deepEqual(result.details.inventoryError.missing, [""]);
	}, mutant.default);
});

test("control: retaining empty array entries makes absent modes conflict", async () => {
	const mutant = await importRuntimeCopy("index.ts",
		'params = { ...params, chain: params.chain?.filter((item) => item.agent && item.task), tasks: params.tasks?.filter((item) => item.agent && item.task) };',
		'params = { ...params, chain: params.chain, tasks: params.tasks };',
	) as typeof import("../extensions/subagent/index.js");
	await withExtensionTools(async (tools, ctx) => {
		const result = await tools.get("subagent").execute("test", rows[2], undefined, undefined, ctx);
		assert.throws(() => assert.equal(result.details.results.length, 1), assert.AssertionError);
	}, mutant.default);
});
