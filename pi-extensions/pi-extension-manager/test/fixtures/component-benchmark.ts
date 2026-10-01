import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Inventory, ManagerUiState } from "../../extensions/manager/types.ts";

// The parent reads the JSON result and the stable benchmark-cache assertion key.
const [source, root, mode] = process.argv.slice(2);
assert(source && root && (mode === "cached" || mode === "main"));
const counts = { buildInventory: 0, packageExtensions: 0, childComparisons: 0, scopedManagerState: 0, completionLabels: 0, commands: 0 };
Object.assign(globalThis, { __managerBenchmark: counts });
const probes = [
	["inventory.ts", "buildInventory", "buildInventory"],
	["process.ts", "runCommand", "commands"],
	["filters.ts", "packageExtensions", "packageExtensions"],
	["filters.ts", "itemBelongsToPackage", "childComparisons"],
	["settings.ts", "scopedManagerState", "scopedManagerState"],
	["quick-settings-ui.ts", "quickSettingRows", "completionLabels"],
] as const;
for (const [file, name, counter] of probes) {
	const path = join(source, "manager", file);
	const text = readFileSync(path, "utf8");
	const pattern = new RegExp(`^(?:export )?(?:async )?function ${name}\\([^\\n]*\\)[^\\n{]*\\{`, "gm");
	assert.equal([...text.matchAll(pattern)].length, 1, `benchmark-probe: function=${name}`);
	const changed = text.replace(pattern, (body) => `${body}\n\tglobalThis.__managerBenchmark.${counter} += 1;`);
	assert.notEqual(changed, text);
	writeFileSync(path, changed);
}
const agent = join(root, "agent");
const cwd = join(root, "project");
function json(path: string, value: unknown): void {
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, JSON.stringify(value));
}
const names = Array.from({ length: 18 }, (_, i) => `@bench/pkg-${String(i).padStart(2, "0")}`);
const schema = { key: "enabled", label: "Enabled", type: "boolean" as const, default: true };
json(join(agent, "settings.json"), {
	packages: names.map((name) => `npm:${name}`),
	kendex: { extensionManager: { config: Object.fromEntries(names.map((name) => [name, { enabled: true }])) } },
});
json(join(cwd, ".pi", "settings.json"), {});
for (const name of names) {
	const dir = join(agent, "npm", "node_modules", name);
	json(join(dir, "package.json"), {
		name, version: "1.0.0", pi: { extensions: ["./extensions/index.ts"] },
		kendex: { extensionManager: { displayName: name, settings: [schema] } },
	});
	mkdirSync(join(dir, "extensions"), { recursive: true });
	writeFileSync(join(dir, "extensions", "index.ts"), "export default function () {}\n");
}

const inventoryModule = await import(join(source, "manager", "inventory.ts"));
const filters = await import(join(source, "manager", "filters.ts"));
const settings = await import(join(source, "manager", "settings.ts"));
const quick = await import(join(source, "manager", "quick-settings-ui.ts"));
const pi = {} as ExtensionAPI;
const ctx = { cwd, hasUI: true, isProjectTrusted: () => true } as unknown as ExtensionContext;
const coldStart = performance.now();
const inventory: Inventory = await inventoryModule.buildInventory(pi, ctx);
const inventoryMs = performance.now() - coldStart;
assert.equal(inventory.packages.length, 18);
assert.equal(inventory.items.filter((item) => item.kind === "extension module").length, 18);
const cachedApi = typeof inventoryModule.inventorySession === "function";
if (cachedApi) inventoryModule.inventorySession(pi).inventory = inventory;
const before = { ...counts };
const ui: ManagerUiState = { search: "", selected: 0, scroll: 0, diagnosticsScroll: 0, stateFilter: "all", scopeFilter: "all", showAudit: false };
const hotStart = performance.now();
for (let step = 0; step < 20; step += 1) {
	const query = step % 2 === 0 ? "pkg" : "pkg-0";
	ui.search = query;
	const completions = cachedApi ? quick.quickSettingsCompletions(pi, query) : quick.quickSettingsCompletions(pi, ctx, query);
	assert.equal(completions?.length, step % 2 === 0 ? 18 : 10);
	assert.equal(filters.filteredItems(inventory.items, ui).length, step % 2 === 0 ? 18 : 10);
	for (const pkg of inventory.packages) {
		assert.equal(filters.packageExtensions(inventory.items, pkg).length, 1);
		assert.deepEqual(settings.getConfigValue(inventory, pkg.packageName!, schema), { explicit: true, scope: "user", value: true });
	}
}
const hotMs = performance.now() - hotStart;
const hotCounts = Object.fromEntries(Object.entries(counts).map(([key, value]) => [key, value - before[key as keyof typeof counts]]));
console.log(JSON.stringify({ inventoryMs, hotMs, packages: names.length, steps: 20, counts, hotCounts }));
if (mode === "cached") {
	assert.equal(hotCounts.buildInventory, 0, "benchmark-cache: inventory");
	assert.equal(hotCounts.completionLabels, 1, "benchmark-cache: completion-labels");
	assert.equal(hotCounts.childComparisons, 18 * 18, "benchmark-cache: children");
	assert.equal(hotCounts.scopedManagerState, 2, "benchmark-cache: scoped-config");
	assert.equal(counts.commands, 0, "benchmark-cache: npm-root");
}
