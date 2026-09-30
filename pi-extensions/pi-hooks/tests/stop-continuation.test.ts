import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { clearPackageConfigCache } from "../extensions/package-config.ts";
import { TURN_END_LISTENER } from "../extensions/registry.ts";
import { CONFIG_ID, readLog, registerRendered, useIsolatedGitEnv } from "./harness.ts";
import { startSession } from "./pi-session.ts";

/**
 * A `Stop` hook's refusal on a Pi session, run in process on the Pi this
 * package's test script installs, with the carrier loaded from its manifest
 * and a scripted model. Pi refuses nothing at a run's end, so the carrier
 * hands the refusal to the model through Pi's own continuation: one more
 * model request inside the same run, whose end dispatches the hooks again
 * with `stop_hook_active: true` and asks for nothing more.
 *
 * `settles` counts `agent_settled`, the end of the run: a carrier that
 * started a second run for the refusal, rather than continuing the first,
 * settles twice for one prompt, and print mode can dispose the runtime
 * between the two.
 */

useIsolatedGitEnv();

const PACKAGE = join(import.meta.dir, "..");
const WORK = "Work the item.";

let world: string;
beforeAll(() => {
	world = realpathSync(mkdtempSync(join(tmpdir(), "pi-hooks-stop-")));
});
afterAll(() => rmSync(world, { recursive: true, force: true }));

/**
 * - `hook` is the user-scope `Stop` registration: `stands-down` speaks until
 *   `stop_hook_active` is true, as doc-drift-check does; `speaks` speaks on
 *   every dispatch; `silent` says nothing.
 * - `want.requests` is what the model was handed, one line per request.
 * - `want.stops` is `stop_hook_active` on each dispatch, in order.
 * - `want.recorded` is what the carrier left in the session, the words of a
 *   dispatch that asks for nothing included.
 */
interface Row {
	name: string;
	hook: "stands-down" | "speaks" | "silent";
	want: { requests: string[]; stops: boolean[]; recorded: string[]; settles: number };
}

const rows: Row[] = [
	{
		name: "a refusal continues the run once, and the hook stands down",
		hook: "stands-down",
		want: { requests: [`user: ${WORK}`, "user: audit=dirty"], stops: [false, true], recorded: ["audit=dirty"], settles: 1 },
	},
	{
		name: "a hook that never stands down is recorded, not continued, on the second stop",
		hook: "speaks",
		want: { requests: [`user: ${WORK}`, "user: audit=dirty"], stops: [false, true], recorded: ["audit=dirty", "audit=again"], settles: 1 },
	},
	{
		name: "a silent hook ends the run",
		hook: "silent",
		want: { requests: [`user: ${WORK}`], stops: [false], recorded: [], settles: 1 },
	},
];

/** Each hook logs its payload as one line, then answers by `stop_hook_active`. */
const HOOKS: Record<Row["hook"], (log: string) => string> = {
	"stands-down": (log) => `p=$(cat); printf '%s\\n' "$p" >> ${JSON.stringify(log)}; case $p in *'"stop_hook_active":true'*) exit 0;; esac; echo 'audit=dirty' >&2; exit 2`,
	speaks: (log) => `p=$(cat); printf '%s\\n' "$p" >> ${JSON.stringify(log)}; case $p in *'"stop_hook_active":true'*) echo 'audit=again' >&2; exit 2;; esac; echo 'audit=dirty' >&2; exit 2`,
	silent: (log) => `printf '%s\\n' "$(cat)" >> ${JSON.stringify(log)}; exit 0`,
};

for (const row of rows) {
	test(`Stop on a Pi session: ${row.name}`, async () => {
		const name = row.name.replace(/[^a-z]+/g, "-");
		const cwd = join(world, name);
		const agentDir = join(world, `${name}-agent`);
		const log = join(world, `${name}.log`);
		mkdirSync(cwd, { recursive: true });
		mkdirSync(agentDir, { recursive: true });
		registerRendered(agentDir, TURN_END_LISTENER, undefined, HOOKS[row.hook](log));
		writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: { enabled: true, sessionDriftCheck: false } } } } }));

		const saved = process.env.PI_CODING_AGENT_DIR;
		process.env.PI_CODING_AGENT_DIR = agentDir;
		clearPackageConfigCache();
		const prompts: string[] = [];
		let settles = 0;
		const session = await startSession({
			cwd,
			agentDir,
			paths: [PACKAGE],
			prompts,
			factories: [(pi) => pi.on("agent_settled", () => { settles += 1; })],
		});
		try {
			// Read the moment the prompt returns, as print mode does before it
			// disposes the runtime: the continuation is part of the prompt.
			await session.prompt(WORK);
			const stops = readLog(log).split("\n").filter((line) => line !== "").map((line) => (JSON.parse(line) as { stop_hook_active: boolean }).stop_hook_active);
			const recorded = session.sessionManager.getBranch().flatMap((entry) =>
				entry.type === "custom_message" && entry.customType === "kendex-hook" ? [String(entry.content)] : []);
			expect({ requests: prompts, stops, recorded, settles }).toEqual(row.want);
		} finally {
			session.dispose();
			if (saved === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = saved;
			clearPackageConfigCache();
		}
	});
}
