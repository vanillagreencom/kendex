// Per-harness subscriber spawn helpers. Each spawn delegates the
// long-running loop body to `scripts/lib/subscribers.bash` so the bash
// and TS daemons share one canonical subscriber implementation.
//
// Spawn pattern (matches bash daemon spawn_{oc,cc,pi,cx}_subscriber):
//   1. Check the pid file; if it points at a live pid, log and reattach.
//   2. spawn('bash', ['lib/subscribers.bash', harness, ...args],
//      detached + stdio ignored).
//   3. Write child.pid to the pid file.
//   4. child.unref() so the parent (daemon) can exit independently.

import { spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
	ocSubscriberPidFile,
} from "../../paths/oc.ts";
import {
	ccSubscriberPidFile,
} from "../../paths/cc.ts";
import {
	piSubscriberPidFile,
} from "../../paths/pi.ts";
import {
	cxSubscriberPidFile,
} from "../../paths/codex.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const SUBSCRIBERS_BASH = resolve(HERE, "../../../../../scripts/lib/subscribers.bash");

function pidAlive(pid: number): boolean {
	if (!Number.isFinite(pid) || pid <= 0) return false;
	try { process.kill(pid, 0); return true; }
	catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
}

function readExistingPid(pidFile: string): number | null {
	if (!existsSync(pidFile)) return null;
	try {
		const txt = readFileSync(pidFile, "utf8").trim();
		if (!/^[1-9][0-9]*$/.test(txt)) return null;
		const pid = Number.parseInt(txt, 10);
		return pidAlive(pid) ? pid : null;
	} catch { return null; }
}

interface BaseSpawnEnv {
	stateDir: string;
	sessionLock: string;
	wakeEventsLog: string;
	logFile: string;
	classifier: string;
	parentPid: number;
}

function baseEnv(opts: BaseSpawnEnv): NodeJS.ProcessEnv {
	return {
		...(process.env as NodeJS.ProcessEnv),
		FD_STATE_DIR: opts.stateDir,
		SESSION_LOCK: opts.sessionLock,
		WAKE_EVENTS_LOG: opts.wakeEventsLog,
		LOG: opts.logFile,
		CLASSIFIER: opts.classifier,
		FD_ENTRY_KIND: "",
		FD_ENTRY_HARNESS: "",
	};
}

function spawnSub(args: string[], env: NodeJS.ProcessEnv, pidFile: string): number {
	const child = spawn("bash", [SUBSCRIBERS_BASH, ...args], {
		env,
		stdio: ["ignore", "ignore", "ignore"],
		detached: true,
	});
	if (typeof child.pid !== "number") {
		throw new Error("subscriber spawn failed: no pid");
	}
	writeFileSync(pidFile, `${child.pid}\n`);
	child.unref();
	return child.pid;
}

export interface SpawnOcOpts extends BaseSpawnEnv {
	sessionKey: string;
	paneId: string;
	ocUrl: string;
	sessionId: string;
	ocLastAssistantJq: string;
	ocPollSec?: number;
	ocBackoffMaxSec?: number;
	log: (tag: string, msg: string) => void;
}

export function spawnOcSubscriber(opts: SpawnOcOpts): { pid: number; reattached: boolean } {
	const pidFile = ocSubscriberPidFile(opts.paneId, opts.sessionKey);
	const existing = readExistingPid(pidFile);
	if (existing !== null) {
		opts.log("oc-subscriber", `pane=${opts.paneId} existing pid=${existing}; reattaching`);
		return { pid: existing, reattached: true };
	}
	const env: NodeJS.ProcessEnv = {
		...baseEnv(opts),
		OC_POLL_SEC: String(opts.ocPollSec ?? 2),
		OC_BACKOFF_MAX_SEC: String(opts.ocBackoffMaxSec ?? 16),
		OC_LAST_ASSISTANT_JQ: opts.ocLastAssistantJq,
	};
	const pid = spawnSub(["oc", opts.paneId, opts.ocUrl, opts.sessionId, String(opts.parentPid)], env, pidFile);
	opts.log("oc-subscriber-spawn", `pane=${opts.paneId} pid=${pid} url=${opts.ocUrl} session=${opts.sessionId}`);
	return { pid, reattached: false };
}

export interface SpawnCcOpts extends BaseSpawnEnv {
	sessionKey: string;
	paneId: string;
	transcript: string;
	ccLastAssistantJq: string;
	log: (tag: string, msg: string) => void;
}

export function spawnCcSubscriber(opts: SpawnCcOpts): { pid: number; reattached: boolean } {
	const pidFile = ccSubscriberPidFile(opts.paneId, opts.sessionKey);
	const existing = readExistingPid(pidFile);
	if (existing !== null) {
		opts.log("cc-subscriber", `pane=${opts.paneId} existing pid=${existing}; reattaching`);
		return { pid: existing, reattached: true };
	}
	const env: NodeJS.ProcessEnv = {
		...baseEnv(opts),
		CC_LAST_ASSISTANT_JQ: opts.ccLastAssistantJq,
	};
	const pid = spawnSub(["cc", opts.paneId, opts.transcript, String(opts.parentPid)], env, pidFile);
	opts.log("cc-subscriber-spawn", `pane=${opts.paneId} pid=${pid} transcript=${opts.transcript}`);
	return { pid, reattached: false };
}

export interface SpawnPiOpts extends BaseSpawnEnv {
	sessionKey: string;
	paneId: string;
	piPid: string;
	piSocket: string;
	expectedSessionId?: string;
	forceSpawn?: boolean;
	piLastAssistantJq: string;
	entryKind?: string;
	entryHarness?: string;
	log: (tag: string, msg: string) => void;
}

export function spawnPiSubscriber(opts: SpawnPiOpts): { pid: number; reattached: boolean } {
	const pidFile = piSubscriberPidFile(opts.paneId, opts.sessionKey);
	const existing = opts.forceSpawn ? null : readExistingPid(pidFile);
	if (existing !== null) {
		opts.log("pi-subscriber", `pane=${opts.paneId} existing pid=${existing}; reattaching`);
		return { pid: existing, reattached: true };
	}
	if (opts.forceSpawn) opts.log("pi-subscriber", `pane=${opts.paneId} force-spawn requested; ignoring existing pidfile`);
	const env: NodeJS.ProcessEnv = {
		...baseEnv(opts),
		PI_LAST_ASSISTANT_JQ: opts.piLastAssistantJq,
		FD_ENTRY_KIND: opts.entryKind ?? "",
		FD_ENTRY_HARNESS: opts.entryHarness ?? "pi",
	};
	const pid = spawnSub(["pi", opts.paneId, opts.piPid, opts.piSocket, String(opts.parentPid), opts.expectedSessionId ?? ""], env, pidFile);
	opts.log("pi-subscriber-spawn", `pane=${opts.paneId} pid=${pid} pi_pid=${opts.piPid} socket=${opts.piSocket} expected_session=${opts.expectedSessionId ?? ""} entry_kind=${opts.entryKind ?? "unknown"}`);
	return { pid, reattached: false };
}

export interface SpawnCxOpts extends BaseSpawnEnv {
	sessionKey: string;
	paneId: string;
	cxUrl: string;
	threadId: string;
	cxLastAssistantJq: string;
	log: (tag: string, msg: string) => void;
}

export function spawnCxSubscriber(opts: SpawnCxOpts): { pid: number; reattached: boolean } {
	const pidFile = cxSubscriberPidFile(opts.paneId, opts.sessionKey);
	const existing = readExistingPid(pidFile);
	if (existing !== null) {
		opts.log("cx-subscriber", `pane=${opts.paneId} existing pid=${existing}; reattaching`);
		return { pid: existing, reattached: true };
	}
	const env: NodeJS.ProcessEnv = {
		...baseEnv(opts),
		CX_LAST_ASSISTANT_JQ: opts.cxLastAssistantJq,
	};
	const pid = spawnSub(["cx", opts.paneId, opts.cxUrl, opts.threadId, String(opts.parentPid)], env, pidFile);
	opts.log("cx-subscriber-spawn", `pane=${opts.paneId} pid=${pid} url=${opts.cxUrl} thread=${opts.threadId}`);
	return { pid, reattached: false };
}
