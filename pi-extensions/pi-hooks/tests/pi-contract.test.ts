import { expect, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

type Uses = Record<string, { events: string[]; calls: string[] }>;
const root = join(import.meta.dir, "..");
const contract = (JSON.parse(readFileSync(join(root, "pi-contract.json"), "utf8")) as { uses: Uses }).uses;

// The Pi update audit consumes this inventory. Pi cannot check repository metadata.
const sources = new Map(readdirSync(join(root, "extensions"), { recursive: true })
	.filter((file) => file.endsWith(".ts"))
	.map((file) => {
		const code = readFileSync(join(root, "extensions", file), "utf8")
			.replace(/\/\*[\s\S]*?\*\/|^\s*\/\/.*$/gm, "");
		const namespace = code.match(/\bpi\s*=\s*await\s+import\(["']([^"']+)["']\)/)?.[1];
		const events = [...new Set([...code.matchAll(/\bpi\.on\(\s*["']([^"']+)["']/g)].map((match) => match[1]))].sort();
		const calls = [...new Set([...code.matchAll(/(?<![\w$.])(?:pi|ctx)(?:\??\.[A-Za-z_$][\w$]*)+/g)]
			.map((match) => match[0].replaceAll("?.", "."))
			.filter((call) => call !== "ctx.cwd" && call !== "ctx.hasUI")
			.map((call) => namespace !== undefined && call.startsWith("pi.") ? namespace + call.slice(2) : call))].sort();
		return [`extensions/${file}`, { events, calls, namespace }] as const;
	}));

function checkContract(uses: Uses): void {
	if (sources.size === 0) throw new Error("pi-contract=extensions-empty");
	for (const file of new Set([...sources.keys(), ...Object.keys(uses)])) {
		const source = sources.get(file);
		const declared = uses[file] ?? { events: [], calls: [] };
		// Named package exports stay manual; a namespace bound to `pi` is scanned.
		const calls = declared.calls.filter((call) => /^(pi|ctx)\./.test(call)
			|| (source?.namespace !== undefined && call.startsWith(`${source.namespace}.`))).sort();
		for (const [field, listed, derived] of [
			["events", [...declared.events].sort(), source?.events ?? []],
			["calls", calls, source?.calls ?? []],
		] as const) {
			if (JSON.stringify(listed) !== JSON.stringify(derived)) {
				throw new Error(`pi-contract=${file}:${field}\nlisted=${JSON.stringify(listed)}\nderived=${JSON.stringify(derived)}`);
			}
		}
	}
}

test("pi-contract matches every extension's literal events and dotted Pi accesses", () => {
	checkContract(contract);
});

for (const { field, direction, value } of [
	{ field: "events", direction: "missing", value: "agent_before_settle" },
	{ field: "events", direction: "extra", value: "session_shutdown" },
	{ field: "calls", direction: "missing", value: "pi.sendMessage" },
	{ field: "calls", direction: "extra", value: "ctx.isIdle" },
] as const) {
	test(`must-fail: ${direction} ${field} entry`, () => {
		const mutant = structuredClone(contract);
		const entry = mutant["extensions/hooks.ts"];
		entry[field] = direction === "missing"
			? entry[field].filter((item) => item !== value)
			: [...entry[field], value];
		expect(() => checkContract(mutant)).toThrow(`pi-contract=extensions/hooks.ts:${field}`);
	});
}