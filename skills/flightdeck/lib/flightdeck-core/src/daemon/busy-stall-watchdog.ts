import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

export const BUSY_STALL_CLASSIFIER_TAG = "pi-busy-stall";
export const BUSY_STALL_ACTIVITY_TYPE = "agent.busy_stalled";

export interface BusyStallConfig {
	enabled: boolean;
	thresholdSec: number;
	cpuPct: number;
	bridgeProbeIntervalSec: number;
	gitProbeIntervalSec: number;
	clockTicksPerSecond: number;
}

export interface ProcessTreeSample {
	pid: number;
	pids: number[];
	state: string;
	running: boolean;
	ticks: number;
}

interface PaneState {
	progressKey: string;
	progressSinceMs: number;
	hotSinceMs: number | null;
	lastCpuTicks: number | null;
	lastCpuSampleMs: number | null;
	lastCpuPct: number;
	lastBridgeProbeMs: number;
	reportedProgressKey: string;
}

export interface BusyStallLocalInput {
	paneId: string;
	harness: string;
	nowMs: number;
	panePid: number | null;
	processSample: ProcessTreeSample | null;
	progressKey: string;
}

export interface BusyStallCandidate {
	paneId: string;
	hash: string;
	details: Record<string, unknown>;
	progressKey: string;
}

export interface BridgeProbeResult {
	responsive: boolean;
	reason: string;
	sessionId?: string;
	socketPath?: string;
}

export interface BusyStallDecision extends BusyStallCandidate {
	tag: typeof BUSY_STALL_CLASSIFIER_TAG;
}

export function busyStallConfigFromEnv(env: NodeJS.ProcessEnv = process.env): BusyStallConfig {
	return {
		bridgeProbeIntervalSec: positiveFloat(env.FD_BUSY_STALL_BRIDGE_PROBE_INTERVAL_SEC, 30),
		clockTicksPerSecond: readClockTicksPerSecond(env),
		cpuPct: positiveFloat(env.FD_BUSY_STALL_CPU_PCT, 90),
		enabled: env.FD_BUSY_STALL_WATCHDOG !== "0",
		gitProbeIntervalSec: positiveFloat(env.FD_BUSY_STALL_GIT_PROBE_INTERVAL_SEC, 30),
		thresholdSec: positiveFloat(env.FD_BUSY_STALL_THRESHOLD_SEC, 300),
	};
}

function positiveFloat(value: string | undefined, fallback: number): number {
	if (!value || !value.trim()) return fallback;
	const parsed = Number.parseFloat(value);
	return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function readClockTicksPerSecond(env: NodeJS.ProcessEnv): number {
	const fromEnv = positiveFloat(env.FD_BUSY_STALL_CLK_TCK, Number.NaN);
	if (Number.isFinite(fromEnv)) return fromEnv;
	const r = spawnSync("getconf", ["CLK_TCK"], { encoding: "utf8", killSignal: "SIGKILL", timeout: 500 });
	const parsed = Number.parseInt((r.stdout ?? "").trim(), 10);
	return Number.isFinite(parsed) && parsed > 0 ? parsed : 100;
}

export class BusyStallWatchdog {
	private panes = new Map<string, PaneState>();

	constructor(private readonly config: BusyStallConfig) {}

	forget(paneId: string): void {
		this.panes.delete(paneId);
	}

	observeLocal(input: BusyStallLocalInput): BusyStallCandidate | null {
		if (!this.config.enabled) return null;
		if (input.harness !== "pi") return null;
		if (!input.processSample || !input.panePid) {
			this.forget(input.paneId);
			return null;
		}
		const state = this.stateFor(input);
		if (state.progressKey !== input.progressKey) {
			state.progressKey = input.progressKey;
			state.progressSinceMs = input.nowMs;
			state.hotSinceMs = null;
			state.reportedProgressKey = "";
		}

		let cpuPct = 0;
		if (state.lastCpuTicks !== null && state.lastCpuSampleMs !== null && input.nowMs > state.lastCpuSampleMs) {
			const deltaTicks = Math.max(0, input.processSample.ticks - state.lastCpuTicks);
			const deltaSec = (input.nowMs - state.lastCpuSampleMs) / 1000;
			cpuPct = deltaSec > 0 ? (deltaTicks / this.config.clockTicksPerSecond / deltaSec) * 100 : 0;
		}
		state.lastCpuTicks = input.processSample.ticks;
		state.lastCpuSampleMs = input.nowMs;
		state.lastCpuPct = cpuPct;

		const hot = input.processSample.running && cpuPct >= this.config.cpuPct;
		if (hot) {
			if (state.hotSinceMs === null) state.hotSinceMs = input.nowMs;
		} else {
			state.hotSinceMs = null;
			state.reportedProgressKey = "";
			return null;
		}

		const noProgressSec = (input.nowMs - state.progressSinceMs) / 1000;
		const hotForSec = state.hotSinceMs === null ? 0 : (input.nowMs - state.hotSinceMs) / 1000;
		if (noProgressSec < this.config.thresholdSec || hotForSec < this.config.thresholdSec) return null;
		if (state.reportedProgressKey === input.progressKey) return null;
		if (input.nowMs - state.lastBridgeProbeMs < this.config.bridgeProbeIntervalSec * 1000) return null;

		return {
			details: {
				cpu_pct: round1(cpuPct),
				hot_for_sec: Math.floor(hotForSec),
				no_progress_sec: Math.floor(noProgressSec),
				pane_pid: input.panePid,
				process_pids: input.processSample.pids,
				process_state: input.processSample.state,
				progress_key_hash: shortHash(input.progressKey),
				recovery_hint: "Bridge is unresponsive while the Pi process is CPU-bound with no output/commit progress; stop and respawn the pane or switch harness if it does not recover.",
			},
			hash: `busy-stall:${shortHash(`${input.paneId}|${input.progressKey}|${state.hotSinceMs}`)}`,
			paneId: input.paneId,
			progressKey: input.progressKey,
		};
	}

	confirmBridge(candidate: BusyStallCandidate, bridge: BridgeProbeResult, nowMs: number): BusyStallDecision | null {
		const state = this.panes.get(candidate.paneId);
		if (!state) return null;
		state.lastBridgeProbeMs = nowMs;
		if (bridge.responsive) return null;
		return {
			...candidate,
			details: {
				...candidate.details,
				bridge_reason: bridge.reason,
				bridge_responsive: false,
				pi_session_id: bridge.sessionId ?? null,
				pi_socket: bridge.socketPath ?? null,
			},
			tag: BUSY_STALL_CLASSIFIER_TAG,
		};
	}

	markReported(candidate: BusyStallCandidate): void {
		const state = this.panes.get(candidate.paneId);
		if (state) state.reportedProgressKey = candidate.progressKey;
	}

	private stateFor(input: BusyStallLocalInput): PaneState {
		let state = this.panes.get(input.paneId);
		if (!state) {
			state = {
				hotSinceMs: null,
				lastBridgeProbeMs: 0,
				lastCpuPct: 0,
				lastCpuSampleMs: null,
				lastCpuTicks: null,
				progressKey: input.progressKey,
				progressSinceMs: input.nowMs,
				reportedProgressKey: "",
			};
			this.panes.set(input.paneId, state);
		}
		return state;
	}
}

function round1(value: number): number {
	return Math.round(value * 10) / 10;
}

function shortHash(value: string): string {
	return createHash("sha256").update(value).digest("hex").slice(0, 12);
}

export function sampleProcessTree(rootPid: number | null): ProcessTreeSample | null {
	if (!rootPid || !Number.isFinite(rootPid) || rootPid <= 0) return null;
	const queue = [Math.trunc(rootPid)];
	const seen = new Set<number>();
	const pids: number[] = [];
	let ticks = 0;
	let running = false;
	const states: string[] = [];
	while (queue.length > 0) {
		const pid = queue.shift()!;
		if (seen.has(pid)) continue;
		seen.add(pid);
		const stat = readProcStat(pid);
		if (!stat) continue;
		pids.push(pid);
		ticks += stat.ticks;
		states.push(`${pid}:${stat.state}`);
		if (stat.state === "R") running = true;
		for (const child of readProcChildren(pid)) if (!seen.has(child)) queue.push(child);
	}
	if (pids.length === 0) return null;
	return { pid: Math.trunc(rootPid), pids, running, state: states.join(","), ticks };
}

function readProcStat(pid: number): { state: string; ticks: number } | null {
	try {
		const text = readFileSync(`/proc/${pid}/stat`, "utf8");
		const endComm = text.lastIndexOf(")");
		if (endComm < 0) return null;
		const rest = text.slice(endComm + 2).trim().split(/\s+/);
		const state = rest[0] ?? "";
		const utime = Number.parseInt(rest[11] ?? "", 10);
		const stime = Number.parseInt(rest[12] ?? "", 10);
		if (!state || !Number.isFinite(utime) || !Number.isFinite(stime)) return null;
		return { state, ticks: utime + stime };
	} catch {
		return null;
	}
}

function readProcChildren(pid: number): number[] {
	try {
		const path = `/proc/${pid}/task/${pid}/children`;
		if (!existsSync(path)) return [];
		return readFileSync(path, "utf8")
			.trim()
			.split(/\s+/)
			.map((part) => Number.parseInt(part, 10))
			.filter((child) => Number.isFinite(child) && child > 0);
	} catch {
		return [];
	}
}

export function readGitHead(cwd: string, timeoutMs = 500): string {
	if (!cwd) return "";
	const r = spawnSync("git", ["-C", cwd, "rev-parse", "HEAD"], { encoding: "utf8", killSignal: "SIGKILL", timeout: timeoutMs });
	if (r.status !== 0) return "";
	return (r.stdout ?? "").trim();
}
