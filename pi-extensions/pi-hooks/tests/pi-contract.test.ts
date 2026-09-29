import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

// pi-contract.json is what the Pi update audit reads to decide whether a
// Breaking Changes entry names something pi-hooks depends on
// (pi-extensions/AGENTS.md). This suite holds it to the source: every event a
// `pi.on` listens on and every call made on the extension API (`pi`) or the
// context (`ctx`), per extension file. The extractor keys on those two names,
// which every extension file uses for the Pi objects; property reads such as
// `ctx.cwd` are not calls and are not listed.

const root = join(import.meta.dir, "..");
const contract = JSON.parse(readFileSync(join(root, "pi-contract.json"), "utf8"));

type Uses = { events: string[]; calls: string[] };

function piUses(source: string): Uses {
	const events = [...source.matchAll(/\bpi\.on\(\s*"([^"]+)"/g)].map((match) => match[1]);
	const calls = [...source.matchAll(/\b(?:pi|ctx)(?:\??\.[A-Za-z_$][\w$]*)+(?=(?:\?\.)?\()/g)]
		.map((match) => match[0].replaceAll("?", ""))
		.filter((call) => call !== "pi.on");
	return { events: [...new Set(events)].sort(), calls: [...new Set(calls)].sort() };
}

function extensionUses(sources: Record<string, string>): Record<string, Uses> {
	const out: Record<string, Uses> = {};
	for (const [file, source] of Object.entries(sources).sort(([a], [b]) => a.localeCompare(b))) {
		const uses = piUses(source);
		if (uses.events.length > 0 || uses.calls.length > 0) out[file] = uses;
	}
	return out;
}

function extensionSources(): Record<string, string> {
	const dir = join(root, "extensions");
	return Object.fromEntries(
		readdirSync(dir)
			.filter((name) => name.endsWith(".ts"))
			.map((name) => [`extensions/${name}`, readFileSync(join(dir, name), "utf8")]),
	);
}

test("pi-contract.json lists every Pi event and call the extension files use, and nothing else", () => {
	const actual = extensionUses(extensionSources());
	// Floor, required members and a forbidden member for the extractor: the
	// carrier exists to answer `tool_call` and steers through `pi.sendMessage`,
	// so a reader that misses either is broken rather than the source sparse,
	// and `pi.on` is the listener form the events column already holds.
	const hooks = actual["extensions/hooks.ts"];
	expect(hooks?.events ?? [], "the pi.on extractor found no tool_call listener in hooks.ts: the extractor is broken").toContain("tool_call");
	expect(hooks?.calls ?? [], "the call extractor found no pi.sendMessage in hooks.ts: the extractor is broken").toContain("pi.sendMessage");
	expect(Object.values(actual).flatMap((uses) => uses.calls)).not.toContain("pi.on");
	expect(contract.uses).toEqual(actual);
});

// Must-fail control: a listener added without its contract entry is reported.
test("a listener the contract does not list fails the comparison", () => {
	const sources = extensionSources();
	const file = "extensions/lane-mail-wake.ts";
	const anchor = 'pi.on("session_shutdown"';
	expect(sources[file]?.split(anchor).length, `${file} no longer holds ${anchor}: this control plants nothing`).toBe(2);
	const planted = { ...sources, [file]: sources[file].replace(anchor, `pi.on("agent_before_settle", () => undefined);\n\t${anchor}`) };
	expect(extensionUses(planted)[file]?.events).toContain("agent_before_settle");
	expect(extensionUses(planted)).not.toEqual(contract.uses);
});
