// Real bridge-idle probe for the idle-stall watchdog (vstack#63
// reviewer follow-up). The original wiring hardcoded isPaneIdle to
// `true`, so a long-running tool call with no registry pokes (large
// test suite, slow model inference) crossed the staleness threshold
// and the watchdog false-fired against a still-working task.
//
// This module exposes a pure helper `probePaneIdle(input, deps)` that
// shells out to `pi-bridge state --socket <s>` (or `--pid <p>`),
// parses the response, and returns true ONLY when the bridge actually
// reports `data.isIdle === true`. Any error, timeout, or missing
// metadata defaults to FALSE (pane-busy) so the watchdog skips rather
// than false-fires.

import type { PaneRegistryEntry, PaneTaskRecord } from "./types.js";

export const BRIDGE_IDLE_PROBE_DEFAULT_TIMEOUT_MS = 2000;

export interface ProbePaneIdleDeps {
	resolveBridgeBin: () => Promise<string | undefined>;
	execCapture: (
		command: string,
		args: string[],
		options?: { cwd?: string; timeoutMs?: number },
	) => Promise<{ code: number; stdout: string; stderr: string }>;
	readPaneRegistryEntry: (agent: string) => Promise<PaneRegistryEntry | undefined>;
	logWarn?: (msg: string) => void;
	timeoutMs?: number;
}

export interface ProbePaneIdleResult {
	idle: boolean;
	reason:
		| "bridge-idle"
		| "bridge-busy"
		| "bridge-missing-metadata"
		| "bridge-bin-not-found"
		| "bridge-error"
		| "bridge-timeout"
		| "bridge-malformed-json"
		| "registry-miss";
}

function parseIsIdle(stdout: string): boolean | undefined {
	try {
		const parsed = JSON.parse(stdout) as unknown;
		if (!parsed || typeof parsed !== "object") return undefined;
		// pi-bridge state returns either {data: {...}, ...} OR a flat state object
		// depending on the bridge version. Accept both shapes.
		const root = parsed as Record<string, unknown>;
		const data = root.data && typeof root.data === "object" ? (root.data as Record<string, unknown>) : root;
		const idle = data.isIdle;
		if (typeof idle === "boolean") return idle;
		return undefined;
	} catch {
		return undefined;
	}
}

function isBridgeSpawnMissing(message: string): boolean {
	return /\bspawn\b/i.test(message) && /\bENOENT\b/i.test(message);
}

export async function probePaneIdle(
	record: PaneTaskRecord,
	deps: ProbePaneIdleDeps,
): Promise<ProbePaneIdleResult> {
	if (!record?.agent) return { idle: false, reason: "registry-miss" };
	const entry = await deps.readPaneRegistryEntry(record.agent);
	if (!entry) return { idle: false, reason: "registry-miss" };
	const pid = entry.bridgePid;
	const socket = entry.bridgeSocket;
	if (!pid && !socket) return { idle: false, reason: "bridge-missing-metadata" };
	const bin = await deps.resolveBridgeBin();
	if (!bin) return { idle: false, reason: "bridge-bin-not-found" };
	const args = socket ? ["state", "--socket", socket] : ["state", "--pid", String(pid)];
	const timeoutMs = deps.timeoutMs ?? BRIDGE_IDLE_PROBE_DEFAULT_TIMEOUT_MS;
	let result: { code: number; stdout: string; stderr: string };
	try {
		result = await deps.execCapture(bin, args, { cwd: entry.cwd, timeoutMs });
	} catch (err) {
		const message = (err as Error)?.message ?? String(err);
		if (isBridgeSpawnMissing(message)) return { idle: false, reason: "bridge-bin-not-found" };
		deps.logWarn?.(`probePaneIdle: ${record.agent} exec threw: ${message}`);
		return { idle: false, reason: /timeout|timed out/i.test(message) ? "bridge-timeout" : "bridge-error" };
	}
	if (result.code !== 0) {
		const stderr = (result.stderr || "").trim();
		if (isBridgeSpawnMissing(stderr)) return { idle: false, reason: "bridge-bin-not-found" };
		deps.logWarn?.(`probePaneIdle: ${record.agent} pi-bridge state exit ${result.code}: ${stderr.slice(0, 200)}`);
		return { idle: false, reason: "bridge-error" };
	}
	const idle = parseIsIdle(result.stdout);
	if (idle === undefined) return { idle: false, reason: "bridge-malformed-json" };
	return { idle, reason: idle ? "bridge-idle" : "bridge-busy" };
}
