import { expect, test } from "bun:test";
import { join } from "node:path";
import { sessionFixture } from "./lib/session-fixture.ts";

// One runtime's claim through its Pi lifecycle: each row fires one event and
// names the session file this process then owns, if any.
const steps = [
	{ event: "session_start", file: "a.jsonl", id: "a-id", owns: "a.jsonl" },
	{ event: "session_start", file: "b.jsonl", id: "b-id", owns: "b.jsonl" },
	{ event: "session_start", file: undefined, id: "c-id", owns: undefined },
	{ event: "session_start", file: "d.jsonl", id: "d-id", owns: "d.jsonl" },
	{ event: "session_shutdown", file: undefined, id: undefined, owns: undefined },
];

test("a runtime claims the session each start opens and releases it at shutdown", async () => {
	const { clearPackageConfigCache } = await import("../extensions/package-config.ts");
	const { installSessionClaim, liveOwner } = await import("../extensions/live-sessions.ts");
	const root = sessionFixture();
	const saved = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(root, "pi-agent");
	clearPackageConfigCache();
	try {
		const handlers = new Map<string, (event: unknown, ctx: unknown) => Promise<void>>();
		installSessionClaim({ on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<void>) => void handlers.set(name, handler) } as never);
		for (const step of steps) {
			const file = step.file && join(root, step.file);
			await handlers.get(step.event)!({ type: step.event }, {
				cwd: root,
				sessionManager: { getSessionFile: () => file, getSessionId: () => step.id },
			});
			for (const name of ["a.jsonl", "b.jsonl", "d.jsonl"]) {
				const owner = await liveOwner(join(root, name), "unclaimed-id");
				expect({ step: step.event, name, owner }).toEqual({
					step: step.event,
					name,
					owner: name === step.owns ? { pid: process.pid, cwd: root, sessionFile: join(root, name), sessionId: step.id! } : undefined,
				});
			}
		}
	} finally {
		if (saved === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = saved;
		clearPackageConfigCache();
	}
});
