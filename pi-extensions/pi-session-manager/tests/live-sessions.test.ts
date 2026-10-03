import { expect, test } from "bun:test";
import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { sessionFixture } from "./lib/session-fixture.ts";

// One process's claim through the Pi lifecycle: each row fires one event, or
// `install` builds the runtime a reload replaces the old one with, and names
// the session file and id this process then owns, if any.
const steps = [
	{ event: "session_start", reason: "startup", file: "a.jsonl", id: "a-id", owns: ["a.jsonl", "a-id"] },
	{ event: "session_start", reason: "new", file: "b.jsonl", id: "b-id", owns: ["b.jsonl", "b-id"] },
	{ event: "session_start", reason: "new", file: undefined, id: "c-id", owns: undefined },
	{ event: "session_start", reason: "resume", file: "d.jsonl", id: "d-id", owns: ["d.jsonl", "d-id"] },
	{ event: "session_shutdown", reason: "reload", file: undefined, id: undefined, owns: ["d.jsonl", "d-id"] },
	{ event: "install", reason: undefined, file: undefined, id: undefined, owns: ["d.jsonl", "d-id"] },
	{ event: "session_start", reason: "reload", file: "d.jsonl", id: "d-id", owns: ["d.jsonl", "d-id"] },
	{ event: "session_shutdown", reason: "quit", file: undefined, id: undefined, owns: undefined },
];

test("a runtime claims the session each start opens, hands the claim over on reload and releases it at shutdown", async () => {
	const { clearPackageConfigCache } = await import("../extensions/package-config.ts");
	const { installSessionClaim, liveOwner } = await import("../extensions/live-sessions.ts");
	const root = sessionFixture();
	const saved = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(root, "pi-agent");
	clearPackageConfigCache();
	const liveDir = join(root, "pi-agent", "kendex", "pi-session-manager", "live");
	const install = () => {
		const handlers = new Map<string, (event: unknown, ctx: unknown) => Promise<void>>();
		installSessionClaim({ on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<void>) => void handlers.set(name, handler) } as never);
		return handlers;
	};
	try {
		let handlers = install();
		const records = new Set<string>();
		for (const step of steps) {
			if (step.event === "install") handlers = install();
			else {
				const file = step.file && join(root, step.file);
				await handlers.get(step.event)!({ type: step.event, reason: step.reason }, {
					cwd: root,
					sessionManager: { getSessionFile: () => file, getSessionId: () => step.id },
				});
			}
			for (const name of ["a.jsonl", "b.jsonl", "d.jsonl"]) {
				const owner = await liveOwner(join(root, name), "unclaimed-id");
				expect({ step: step.event, name, owner }).toEqual({
					step: step.event,
					name,
					owner: step.owns && name === step.owns[0] ? { pid: process.pid, cwd: root, sessionFile: join(root, name), sessionId: step.owns[1] } : undefined,
				});
			}
			const present = existsSync(liveDir) ? readdirSync(liveDir) : [];
			expect({ step: step.event, count: present.length }).toEqual({ step: step.event, count: step.owns ? 1 : 0 });
			for (const name of present) records.add(name);
		}
		// Every claim, the reloaded runtime's included, wrote one record.
		expect(records.size).toBe(1);
	} finally {
		if (saved === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = saved;
		clearPackageConfigCache();
	}
});
