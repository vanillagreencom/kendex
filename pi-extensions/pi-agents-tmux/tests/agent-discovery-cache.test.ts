// Pi renders tool calls after session startup or execution loads the inventory.
// File notifications come from Node's stat polling, not from the renderer.
import assert from "node:assert/strict";
import * as fs from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { spyOn } from "bun:test";
import { cachedAgentDiscovery, discoverAgents } from "../extensions/subagent/agents.js";
import { subagentToolRenderers } from "../extensions/subagent/subagent-render.js";
import {
	assertBulkDiscoveryUpdate, assertDiscoveryEviction, cleanupTempRuntimes, filesystemCalls, importRuntimeCopy, notifyFileCheck,
	stripAnsi, tempRuntime, theme, withTempPiUserDir, writeProjectAgent, writeSettings,
} from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("second unchanged render uses memory, including on a cold inventory", () => {
	withTempPiUserDir(() => {
		const cwd = tempRuntime();
		writeSettings(cwd, { dashboard: false });
		writeProjectAgent(cwd, "scout", ["pane: true"]);
		const args = { agent: "scout", task: "Inspect." };
		// Warm settings separately; cold discovery must not fill itself in rendering.
		subagentToolRenderers.renderCall(args, theme, { cwd });
		assert.equal(cachedAgentDiscovery(cwd, "project"), undefined);
		assert.deepEqual(filesystemCalls(() => subagentToolRenderers.renderCall(args, theme, { cwd })), [0, 0, 0, 0, 0]);
		const first = discoverAgents(cwd, "project");
		assert.equal(subagentToolRenderers.renderCall(args, theme, { cwd }).render(220).join("\n"), "");
		assert.deepEqual(filesystemCalls(() => subagentToolRenderers.renderCall(args, theme, { cwd })), [0, 0, 0, 0, 0]);
		const calls = filesystemCalls(() => assert.equal(discoverAgents(cwd, "project"), first));
		assert.equal(calls[0], 0, "revalidation reuses parsed files");
	});
});

for (const scope of ["project", "user"] as const) {
	test(`listed ${scope} file mtime change updates the next render without a discovery call`, () => {
		withTempPiUserDir((userDir) => {
			const cwd = tempRuntime();
			writeSettings(cwd, { dashboard: false });
			writeProjectAgent(cwd, "scout", ["pane: false"]);
			const projectFile = join(cwd, ".pi/agents/scout.md");
			const file = scope === "project" ? projectFile : join(userDir, "agents/scout.md");
			if (scope === "user") {
				fs.mkdirSync(join(userDir, "agents"));
				fs.copyFileSync(projectFile, file);
			}
			const watch = spyOn(fs, "watchFile");
			try {
				discoverAgents(cwd, scope);
				const args = { agent: "scout", task: "Inspect.", agentScope: scope };
				const first = stripAnsi(subagentToolRenderers.renderCall(args, theme, { cwd }).render(220).join("\n"));
				assert.match(first, /scout/);
				writeProjectAgent(cwd, "scout", ["pane: true", "allowed-subagents: researcher"]);
				if (scope === "user") fs.copyFileSync(projectFile, file);
				const oldTime = fs.statSync(file).mtimeMs;
				fs.utimesSync(file, oldTime / 1000, (oldTime + 2000) / 1000);
				notifyFileCheck(watch, file);
				assert.deepEqual(cachedAgentDiscovery(cwd, scope)?.agents.find((agent) => agent.name === "scout")?.allowedSubagents, ["researcher"]);
				assert.deepEqual(filesystemCalls(() => {
					assert.equal(subagentToolRenderers.renderCall(args, theme, { cwd }).render(220).join("\n"), "");
				}), [0, 0, 0, 0, 0]);
			} finally { watch.mockRestore(); }
		});
	});
}

for (const combinations of [1, 8]) {
	test(`bulk listed-file updates check only changed files across ${combinations} inventories`, () => {
		assertBulkDiscoveryUpdate({ discoverAgents, cachedAgentDiscovery }, combinations);
	});
}

test("must-fail control: full scans on every notification violate the bulk-update assertion", async () => {
	const mutant = await importRuntimeCopy("agents.ts",
		'source === "directory" ? this.refresh() : this.refreshFile(file, source)',
		'source === "directory" ? this.refresh() : this.refresh()') as typeof import("../extensions/subagent/agents.js");
	assert.throws(() => assertBulkDiscoveryUpdate(mutant, 1), assert.AssertionError);
});

// Directory listings are written by agent installation, removal and rename.
const directoryRows = ["add", "remove", "rename", "nearer"] as const;
for (const change of directoryRows) {
	test(`directory listing change: ${change}`, () => {
		withTempPiUserDir(() => {
			const root = tempRuntime();
			const cwd = join(root, "src");
			fs.mkdirSync(cwd);
			writeSettings(cwd, { dashboard: false });
			subagentToolRenderers.renderCall({ agent: "missing", task: "Inspect." }, theme, { cwd });
			writeProjectAgent(root, "scout", ["pane: true"]);
			const watch = spyOn(fs, "watchFile");
			try {
				discoverAgents(cwd, "project");
				const dir = join(change === "nearer" ? cwd : root, ".pi/agents");
				switch (change) {
					case "add": writeProjectAgent(root, "reviewer", ["pane: true"]); break;
					case "remove": fs.unlinkSync(join(dir, "scout.md")); break;
					case "rename":
						fs.renameSync(join(dir, "scout.md"), join(dir, "renamed.md"));
						writeProjectAgent(root, "renamed", ["pane: true"]); break;
					case "nearer": writeProjectAgent(cwd, "local", ["pane: true"]); break;
				}
				notifyFileCheck(watch, dir);
				const expected = { add: ["reviewer", "scout"], remove: [], rename: ["renamed"], nearer: ["local"] }[change];
				assert.deepEqual(cachedAgentDiscovery(cwd, "project")?.agents.map((agent) => agent.name), expected);
				const name = expected[0] ?? "scout";
				assert.deepEqual(filesystemCalls(() => {
					const rendered = subagentToolRenderers.renderCall({ agent: name, task: "Inspect." }, theme, { cwd }).render(220).join("\n");
					assert.equal(rendered === "", change !== "remove");
				}), [0, 0, 0, 0, 0]);
				if (change === "nearer") {
					fs.rmSync(dir, { recursive: true });
					notifyFileCheck(watch, dir);
					assert.deepEqual(cachedAgentDiscovery(cwd, "project")?.agents.map(({ name, filePath }) => ({ name, filePath })),
						[{ name: "scout", filePath: join(root, ".pi/agents/scout.md") }]);
				}
			} finally { watch.mockRestore(); }
		});
	});
}

test("symlink target edits invalidate parsed content", () => {
	withTempPiUserDir(() => {
		const cwd = tempRuntime();
		const target = tempRuntime();
		writeProjectAgent(target, "scout", ["pane: false"]);
		fs.mkdirSync(join(cwd, ".pi/agents"), { recursive: true });
		const file = join(cwd, ".pi/agents/scout.md");
		fs.symlinkSync(join(target, ".pi/agents/scout.md"), file);
		const watch = spyOn(fs, "watchFile");
		try {
			discoverAgents(cwd, "project");
			writeProjectAgent(target, "scout", ["pane: true"]);
			notifyFileCheck(watch, file);
			assert.equal(cachedAgentDiscovery(cwd, "project")?.agents[0]?.pane, true);
		} finally { watch.mockRestore(); }
	});
});

test("cache eviction releases checks and retains the requested project's inventory", () => {
	assertDiscoveryEviction({ discoverAgents, cachedAgentDiscovery });
});

const evictionControls = [
	{
		name: "retaining directory subscriptions",
		before: "for (const [file, listener] of this.subscriptions) fs.unwatchFile(file, listener);",
		after: 'for (const [file, listener] of this.subscriptions) if (file.endsWith(".md")) fs.unwatchFile(file, listener);',
	},
	{
		name: "returning another directory's memo",
		before: "const memo = discoveryMemos.get(key);",
		after: "const memo = discoveryMemos.values().next().value;",
	},
];
for (const control of evictionControls) {
	test(`must-fail control: ${control.name} violates eviction assertions`, async () => {
		const mutant = await importRuntimeCopy("agents.ts", control.before, control.after) as typeof import("../extensions/subagent/agents.js");
		assert.throws(() => assertDiscoveryEviction(mutant), assert.AssertionError);
	});
}

test("must-fail control: render-time discovery violates the no-disk assertion", async () => {
	const mutant = await importRuntimeCopy("subagent-render.ts",
		'import { cachedAgentDiscovery, type AgentScope }',
		'import { discoverAgents as cachedAgentDiscovery, type AgentScope }') as typeof import("../extensions/subagent/subagent-render.js");
	withTempPiUserDir(() => {
		const cwd = tempRuntime();
		writeSettings(cwd, { dashboard: false });
		writeProjectAgent(cwd, "scout");
		discoverAgents(cwd, "project");
		mutant.subagentToolRenderers.renderCall({ agent: "scout" }, theme, { cwd });
		const calls = filesystemCalls(() => mutant.subagentToolRenderers.renderCall({ agent: "scout" }, theme, { cwd }));
		assert.throws(() => assert.deepEqual(calls, [0, 0, 0, 0, 0]), assert.AssertionError);
	});
});

test("must-fail control: ignoring file metadata keeps the changed agent stale", async () => {
	const mutant = await importRuntimeCopy("agents.ts", "cached?.version === version", "cached !== undefined") as typeof import("../extensions/subagent/agents.js");
	withTempPiUserDir(() => {
		const cwd = tempRuntime();
		writeProjectAgent(cwd, "scout", ["pane: false"]);
		const watch = spyOn(fs, "watchFile");
		try {
			mutant.discoverAgents(cwd, "project");
			writeProjectAgent(cwd, "scout", ["pane: true"]);
			notifyFileCheck(watch, join(cwd, ".pi/agents/scout.md"));
			assert.throws(() => assert.equal(mutant.cachedAgentDiscovery(cwd, "project")?.agents[0]?.pane, true), assert.AssertionError);
		} finally { watch.mockRestore(); }
	});
});
