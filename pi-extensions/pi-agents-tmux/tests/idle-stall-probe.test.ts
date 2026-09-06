// The bridge idle probe as one table over the registry entry, the bridge
// binary and what `pi-bridge state` does: each row reads back as idle or
// busy with the reason, the exec it made (arguments, cwd, timeout) and the
// warnings it logged. Anything but a bridge that answers isIdle reads busy,
// so the watchdog skips rather than fires.

import assert from "node:assert/strict";
import test from "node:test";
import { probePaneIdle, type ProbePaneIdleDeps, type ProbePaneIdleResult } from "../extensions/subagent/idle-stall-probe.js";
import type { PaneRegistryEntry, PaneTaskRecord } from "../extensions/subagent/types.js";

const RECORD: PaneTaskRecord = { agent: "planner", createdAt: "2026-05-15T12:00:00.000Z", status: "running", task: "Plan.", taskId: "task-stall-1", updatedAt: "2026-05-15T12:00:00.000Z" };
const ENTRY: PaneRegistryEntry = { agent: "planner", bridgePid: "12345", bridgeSocket: "/tmp/pi-bridge.sock", cwd: "/tmp/cwd", launcherFile: "/tmp/launcher.sh", paneId: "%7", promptFile: "/tmp/prompt.md", sessionFile: "/tmp/session.jsonl", startedAt: "2026-05-15T12:00:00.000Z", windowName: "agent-planner" };
const BIN = "/usr/bin/pi-bridge";

type Exec = { code: number; stdout: string; stderr: string; error?: unknown };
interface Opts {
	record?: PaneTaskRecord;
	entry?: Partial<PaneRegistryEntry> | null;
	bin?: string | null;
	exec?: Exec;
	throws?: unknown;
	timeoutMs?: number;
}

// A spawn ENOENT as node raises it: the code, the syscall and the path.
function spawnEnoent(path = BIN): Error {
	return Object.assign(new Error(`spawn ${path} ENOENT`), { code: "ENOENT", path, syscall: "spawn" });
}
function state(body: unknown): Exec {
	return { code: 0, stderr: "", stdout: JSON.stringify(body) };
}

// A warning by the failure it names, with what it carried; any other line
// printed whole.
function warnTag(line: string): string {
	const threw = /exec threw: (.*)$/.exec(line);
	if (threw) return `threw(${JSON.stringify(threw[1])})`;
	const exit = /pi-bridge state exit (\d+): (.*)$/.exec(line);
	if (exit) return `exit${exit[1]}(${JSON.stringify(exit[2])})`;
	return JSON.stringify(line);
}

async function probeLine(opts: Opts): Promise<string> {
	const execs: string[] = [];
	const warnings: string[] = [];
	const deps: ProbePaneIdleDeps = {
		resolveBridgeBin: async () => (opts.bin === null ? undefined : (opts.bin ?? BIN)),
		execCapture: async (command, args, options) => {
			execs.push(`${command === BIN ? "bin" : JSON.stringify(command)} ${args.join(" ")} cwd=${options?.cwd} timeout=${options?.timeoutMs}`);
			if (opts.throws !== undefined) throw opts.throws;
			return opts.exec ?? { code: 0, stderr: "", stdout: "" };
		},
		readPaneRegistryEntry: async () => (opts.entry === null ? undefined : { ...ENTRY, ...opts.entry }),
		logWarn: (msg) => void warnings.push(msg),
		...(opts.timeoutMs === undefined ? {} : { timeoutMs: opts.timeoutMs }),
	};
	let result: ProbePaneIdleResult;
	try {
		result = await probePaneIdle(opts.record ?? RECORD, deps);
	} catch (err) {
		return `threw(${JSON.stringify((err as Error).message)})`;
	}
	return `${result.idle ? "idle" : "busy"}:${result.reason} exec=[${execs.join(";")}]${warnings.length ? ` warn=[${warnings.map(warnTag).join(",")}]` : ""}`;
}

const SOCKET_EXEC = "exec=[bin state --socket /tmp/pi-bridge.sock cwd=/tmp/cwd timeout=2000]";

// label | deps | expect
const rows: Array<[string, Opts, string]> = [
	["the bridge answers idle under its data wrapper", { exec: state({ data: { isIdle: true } }) }, `idle:bridge-idle ${SOCKET_EXEC}`],
	["the bridge answers busy under its data wrapper", { exec: state({ data: { isIdle: false } }) }, `busy:bridge-busy ${SOCKET_EXEC}`],
	["a flat state answers idle", { exec: state({ isIdle: true }) }, `idle:bridge-idle ${SOCKET_EXEC}`],
	["a flat state answers busy", { exec: state({ isIdle: false }) }, `busy:bridge-busy ${SOCKET_EXEC}`],
	["a data field that is not an object falls back to the flat shape", { exec: state({ data: "v2", isIdle: true }) }, `idle:bridge-idle ${SOCKET_EXEC}`],
	["an isIdle that is not a boolean is malformed", { exec: state({ data: { isIdle: "true" } }) }, `busy:bridge-malformed-json ${SOCKET_EXEC}`],
	["a state without isIdle is malformed", { exec: state({ data: {} }) }, `busy:bridge-malformed-json ${SOCKET_EXEC}`],
	["a JSON null is malformed", { exec: state(null) }, `busy:bridge-malformed-json ${SOCKET_EXEC}`],
	["output that is not JSON is malformed", { exec: { code: 0, stderr: "", stdout: "not json" } }, `busy:bridge-malformed-json ${SOCKET_EXEC}`],
	["a spawn ENOENT on the bridge binary is the binary missing, unwarned", { throws: spawnEnoent() }, `busy:bridge-bin-not-found ${SOCKET_EXEC}`],
	["a non-zero result carrying that ENOENT is the same, unwarned", { exec: { code: 1, error: spawnEnoent(), stderr: "Error: spawn /usr/bin/pi-bridge ENOENT", stdout: "" } }, `busy:bridge-bin-not-found ${SOCKET_EXEC}`],
	["an ENOENT in prose only is a bridge error and warned", { throws: new Error("spawn /usr/bin/pi-bridge ENOENT") }, `busy:bridge-error ${SOCKET_EXEC} warn=[threw("spawn /usr/bin/pi-bridge ENOENT")]`],
	["a spawn ENOENT on another path is a bridge error and warned", { throws: spawnEnoent("/tmp/not-pi-bridge") }, `busy:bridge-error ${SOCKET_EXEC} warn=[threw("spawn /tmp/not-pi-bridge ENOENT")]`],
	["an ENOENT on the binary path from another syscall is a bridge error and warned", { throws: Object.assign(new Error("open /usr/bin/pi-bridge ENOENT"), { code: "ENOENT", path: BIN, syscall: "open" }) }, `busy:bridge-error ${SOCKET_EXEC} warn=[threw("open /usr/bin/pi-bridge ENOENT")]`],
	["an ENOENT thrown as bare text is a bridge error and warned", { throws: "spawn /usr/bin/pi-bridge ENOENT" }, `busy:bridge-error ${SOCKET_EXEC} warn=[threw("spawn /usr/bin/pi-bridge ENOENT")]`],
	["any other throw is a bridge error and warned", { throws: new Error("ECONNRESET") }, `busy:bridge-error ${SOCKET_EXEC} warn=[threw("ECONNRESET")]`],
	["a throw naming a timeout is a bridge timeout and warned", { throws: new Error("pi-bridge state timed out after 2000ms") }, `busy:bridge-timeout ${SOCKET_EXEC} warn=[threw("pi-bridge state timed out after 2000ms")]`],
	["a throw that is not an Error is printed as text", { throws: "socket closed" }, `busy:bridge-error ${SOCKET_EXEC} warn=[threw("socket closed")]`],
	["a non-zero exit is a bridge error warned with its stderr", { exec: { code: 1, stderr: "no such session\n", stdout: "" } }, `busy:bridge-error ${SOCKET_EXEC} warn=[exit1("no such session")]`],
	["a non-zero exit without stderr is warned with its error", { exec: { code: 2, error: new Error("killed by signal"), stderr: "", stdout: "" } }, `busy:bridge-error ${SOCKET_EXEC} warn=[exit2("killed by signal")]`],
	["a non-zero exit with neither is warned as such", { exec: { code: 3, stderr: "", stdout: "" } }, `busy:bridge-error ${SOCKET_EXEC} warn=[exit3("non-zero exit")]`],
	["a long stderr is cut at two hundred characters", { exec: { code: 1, stderr: "x".repeat(250), stdout: "" } }, `busy:bridge-error ${SOCKET_EXEC} warn=[exit1(${JSON.stringify("x".repeat(200))})]`],
	["no registry entry for the agent", { entry: null }, "busy:registry-miss exec=[]"],
	["a record without an agent", { record: { ...RECORD, agent: "" } }, "busy:registry-miss exec=[]"],
	["an entry without bridge metadata", { entry: { bridgePid: undefined, bridgeSocket: undefined } }, "busy:bridge-missing-metadata exec=[]"],
	["no bridge binary", { bin: null }, "busy:bridge-bin-not-found exec=[]"],
	["a pid alone is probed by pid", { entry: { bridgePid: "9999", bridgeSocket: undefined }, exec: state({ data: { isIdle: true } }) }, "idle:bridge-idle exec=[bin state --pid 9999 cwd=/tmp/cwd timeout=2000]"],
	["a socket beside a pid wins", { entry: { bridgePid: "9999", bridgeSocket: "/run/b.sock" }, exec: state({ data: { isIdle: true } }) }, "idle:bridge-idle exec=[bin state --socket /run/b.sock cwd=/tmp/cwd timeout=2000]"],
	["an injected timeout is handed to the exec", { exec: state({ data: { isIdle: true } }), timeoutMs: 500 }, "idle:bridge-idle exec=[bin state --socket /tmp/pi-bridge.sock cwd=/tmp/cwd timeout=500]"],
	["the resolved binary is the command", { bin: "/opt/pi-bridge", exec: state({ data: { isIdle: true } }) }, 'idle:bridge-idle exec=["/opt/pi-bridge" state --socket /tmp/pi-bridge.sock cwd=/tmp/cwd timeout=2000]'],
];

test("probePaneIdle", async () => {
	for (const [label, opts, expect] of rows) assert.equal(await probeLine(opts), expect, label);
});
