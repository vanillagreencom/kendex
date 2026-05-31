// Port of scripts/lib/pi-bridge-paths.sh — pi Session Bridge adapter.
// One Unix-socket bridge per pi pid, discovered post-spawn from
// `pi-bridge list --json`.

import { spawnSync, type SpawnSyncOptionsWithStringEncoding, type SpawnSyncReturns } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { join } from "node:path";
import { fdResolveStateDir } from "./daemon.ts";

export const piSpawnFile = (issue: string) => join(fdResolveStateDir(), `pi-spawn-${issue}.json`);
export const piPaneIdSafe = (id: string) => id.replace(/^%/, "");
export const piSubscriberPidFile = (paneId: string, sessionKey: string) =>
	join(fdResolveStateDir(), `fd-pi-subscriber-${sessionKey}-${piPaneIdSafe(paneId)}.pid`);

export const PI_BRIDGE_DEFAULT_READ_TIMEOUT_SEC = 2;

type PiBridgeSpawnOptions = Omit<SpawnSyncOptionsWithStringEncoding, "encoding" | "timeout" | "killSignal"> & {
	timeoutMs?: number;
};

export function piBridgeReadTimeoutMs(env: NodeJS.ProcessEnv = process.env): number {
	const raw = env.FD_PI_BRIDGE_READ_TIMEOUT_SEC ?? env.FD_ADAPTER_READ_TIMEOUT_SEC ?? String(PI_BRIDGE_DEFAULT_READ_TIMEOUT_SEC);
	const parsed = Number.parseFloat(raw);
	if (!Number.isFinite(parsed) || parsed <= 0) return PI_BRIDGE_DEFAULT_READ_TIMEOUT_SEC * 1000;
	return Math.ceil(parsed * 1000);
}

export function piBridgeSpawnSync(bin: string, args: string[], options: PiBridgeSpawnOptions = {}): SpawnSyncReturns<string> {
	const { timeoutMs, ...rest } = options;
	return spawnSync(bin, args, {
		...rest,
		encoding: "utf8",
		killSignal: "SIGKILL",
		timeout: timeoutMs ?? piBridgeReadTimeoutMs(),
	});
}

function isExecutable(path: string): boolean {
	try {
		// Bash uses `[[ -x ... ]]` — check stat mode bits.
		const s = statSync(path);
		return s.isFile() && (s.mode & 0o111) !== 0;
	} catch { return false; }
}

// Prefer PI_BRIDGE_BIN, then PATH, then ~/.pi/agent/bin/pi-bridge.
export function piResolveBridgeBin(): string | null {
	const env = process.env.PI_BRIDGE_BIN;
	if (env && isExecutable(env)) return env;
	const which = spawnSync("command", ["-v", "pi-bridge"], { encoding: "utf8", killSignal: "SIGKILL", shell: "/bin/bash", timeout: 500 });
	const fromPath = (which.stdout ?? "").trim();
	if (fromPath && isExecutable(fromPath)) return fromPath;
	const canonical = join(homedir(), ".pi/agent/bin/pi-bridge");
	if (isExecutable(canonical)) return canonical;
	return null;
}

export function piResolvePiBin(): string | null {
	const env = process.env.PI_BIN;
	if (env && isExecutable(env)) return env;
	if (isExecutable("/usr/bin/pi")) return "/usr/bin/pi";
	const r = spawnSync("bash", ["-c", "type -P pi 2>/dev/null"], { encoding: "utf8", killSignal: "SIGKILL", timeout: 500 });
	const path = (r.stdout ?? "").trim();
	if (path && isExecutable(path)) return path;
	return null;
}

function projectPiDir(start = process.cwd()): string | null {
	let current = resolve(start);
	while (true) {
		const candidate = join(current, ".pi");
		if (existsSync(candidate)) return candidate;
		const parent = dirname(current);
		if (parent === current) return null;
		current = parent;
	}
}

export function piBridgeExtensionCandidates(home = homedir(), cwd = process.cwd()): string[] {
	const projectPi = projectPiDir(cwd);
	const candidates: string[] = [];
	if (projectPi) {
		candidates.push(
			join(projectPi, "packages/pi-session-bridge/extensions/session-bridge.ts"),
			join(projectPi, "npm/node_modules/@vanillagreen/pi-session-bridge/extensions/session-bridge.ts"),
		);
	}
	candidates.push(
		join(home, ".pi/agent/packages/pi-session-bridge/extensions/session-bridge.ts"),
		join(home, ".pi/agent/npm/node_modules/@vanillagreen/pi-session-bridge/extensions/session-bridge.ts"),
	);
	return candidates;
}

export function piResolveBridgeExtension(): string | null {
	const env = process.env.PI_SESSION_BRIDGE_EXTENSION;
	if (env && existsSync(env)) return env;
	for (const candidate of piBridgeExtensionCandidates()) {
		if (existsSync(candidate)) return candidate;
	}
	return null;
}

interface BridgeListRow { pid: number; cwd: string; sessionId?: string; startedAt?: number; started_at?: number }

function listBridges(bin: string): BridgeListRow[] {
	const r = piBridgeSpawnSync(bin, ["list", "--json"]);
	if (r.status !== 0) return [];
	try {
		const arr = JSON.parse(r.stdout ?? "[]");
		return Array.isArray(arr) ? arr : [];
	} catch { return []; }
}

export function piSnapshotPids(): number[] {
	const bin = piResolveBridgeBin();
	if (!bin) return [];
	return listBridges(bin).map((row) => row.pid).filter((p) => Number.isFinite(p) && p > 0);
}

// Wait for a new pi-bridge pid matching the worktree cwd, excluding
// the pre-snapshot pids.
export async function piDiscoverPid(wtPath: string, timeoutSec = 30, prePids: number[] = []): Promise<number | null> {
	const bin = piResolveBridgeBin();
	if (!bin) return null;
	const absWt = resolve(wtPath);
	const deadline = Date.now() + timeoutSec * 1000;
	const preSet = new Set(prePids);
	while (Date.now() < deadline) {
		const rows = listBridges(bin)
			.filter((r) => (r.cwd ?? "") === absWt)
			.filter((r) => !preSet.has(r.pid));
		if (rows.length > 0) {
			rows.sort((a, b) => (a.startedAt ?? a.started_at ?? 0) - (b.startedAt ?? b.started_at ?? 0));
			return rows[rows.length - 1]!.pid;
		}
		await new Promise((r) => setTimeout(r, 500));
	}
	return null;
}

export function piBridgeIsFresh(pid: number, socket: string): boolean {
	return piBridgeStateProbe(pid, socket).ok;
}

export type PiBridgeStateProbeResult =
	| { ok: true; sessionId?: string; socketPath?: string }
	| { ok: false; reason: string; status?: number | null; signal?: NodeJS.Signals | null; errorCode?: string };

export function piBridgeStateProbe(pid: number | string, socket = "", timeoutMs = piBridgeReadTimeoutMs()): PiBridgeStateProbeResult {
	const pidNum = typeof pid === "number" ? pid : Number(pid);
	if (!Number.isFinite(pidNum) || pidNum <= 0) return { ok: false, reason: "invalid-pid" };
	try { process.kill(pidNum, 0); } catch (e) {
		const code = (e as NodeJS.ErrnoException).code;
		if (code !== "EPERM") return { ok: false, reason: "pid-not-alive", errorCode: code };
	}
	if (socket) {
		if (!existsSync(socket)) return { ok: false, reason: "socket-missing" };
		try {
			const s = statSync(socket);
			if (!s.isSocket()) return { ok: false, reason: "socket-not-socket" };
		} catch (error) {
			return { ok: false, reason: "socket-stat-failed", errorCode: (error as NodeJS.ErrnoException).code };
		}
	}
	const bin = piResolveBridgeBin();
	if (!bin) return { ok: false, reason: "bridge-bin-missing" };
	const target = socket ? ["--socket", socket] : ["--pid", String(pidNum)];
	const r = piBridgeSpawnSync(bin, ["state", ...target], { timeoutMs });
	if (r.error) {
		const code = (r.error as NodeJS.ErrnoException).code;
		return { ok: false, reason: code === "ETIMEDOUT" ? "bridge-timeout" : "bridge-spawn-error", errorCode: code, signal: r.signal };
	}
	if (r.status !== 0) return { ok: false, reason: "bridge-exit", signal: r.signal, status: r.status };
	try {
		const obj = JSON.parse(r.stdout ?? "{}");
		const data = obj?.data && typeof obj.data === "object" ? obj.data : obj;
		if (data?.protocol !== "pi-session-bridge.v1") return { ok: false, reason: "protocol-mismatch" };
		return {
			ok: true,
			sessionId: typeof data.sessionId === "string" ? data.sessionId : typeof data.session_id === "string" ? data.session_id : undefined,
			socketPath: typeof data.socketPath === "string" ? data.socketPath : typeof data.socket === "string" ? data.socket : undefined,
		};
	} catch {
		return { ok: false, reason: "malformed-json" };
	}
}

// jq filter for last assistant text from `pi-bridge history`.
export const PI_LAST_ASSISTANT_JQ = `
  ( .data.events // [] )
  | map(select(.data.message.role == "assistant" and (.data.message.stopReason // "") != ""))
  | last
  | if . == null then ""
    else
      ( .data.message.content // [] )
      | (if type == "array" then map(select(.type == "text") | .text // "") | join("") else . end)
    end
`;
