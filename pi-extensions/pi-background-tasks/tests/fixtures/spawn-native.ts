import { mock } from "bun:test";
import nativeChildProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { EventEmitter } from "node:events";
import * as filesystem from "node:fs";
import * as filesystemPromises from "node:fs/promises";
import { PassThrough } from "node:stream";

export const fixturePid = 4242;
export const fixtureNow = 1_700_000_000_000;

// deferProcReads holds each asynchronous /proc read until releaseProcReads();
// deferAppends holds each asynchronous file append until releaseAppends().
export async function interceptNativeEffects(options: { stopFails?: boolean; killFails?: boolean; signalGone?: boolean; deferProcReads?: boolean; deferAppends?: boolean } = {}) {
	const signals: { pid: number; signal: unknown }[] = [];
	const childSignals: unknown[] = [];
	const spawns: { file: string; args: string[]; options: Record<string, unknown> }[] = [];
	const syncCalls: { file: string; args: string[] }[] = [];
	const probeCalls: { file: string; args: string[] }[] = [];
	const unexpected: string[] = [];
	const children: FakeChild[] = [];
	const originalChildModule = { ...nativeChildProcess };
	const originalReadFileSync = filesystem.readFileSync;
	const originalReadFile = filesystemPromises.readFile;
	const originalAppendFile = filesystemPromises.appendFile;
	const originalKill = process.kill;
	const originalNow = Date.now;
	const originalTimers = { setTimeout, clearTimeout, setInterval, clearInterval };
	const originalBun = { spawn: Bun.spawn, spawnSync: Bun.spawnSync };
	const forbidden = (...args: unknown[]): never => {
		unexpected.push(JSON.stringify(args));
		throw new Error(`spawn_fixture.native_operation=${JSON.stringify(args)}`);
	};
	const kill = (pid: number, signal?: string | number) => {
		signals.push({ pid, signal });
		if (options.signalGone) throw Object.assign(new Error("fixture process is gone"), { code: "ESRCH" });
		return true;
	};
	class FakeChild extends EventEmitter {
		pid = fixturePid;
		stdout = new PassThrough();
		stderr = new PassThrough();
		kill(signal?: unknown) { childSignals.push(signal); return true; }
		unref() { forbidden("child.unref"); }
	}
	const spawn = (file: string, args: string[], spawnOptions: Record<string, unknown>) => {
		spawns.push({ file, args, options: spawnOptions });
		const child = new FakeChild();
		children.push(child);
		return child;
	};
	const spawnSync = (file: string, args: string[]) => {
		syncCalls.push({ file, args });
		if (file === "sh" && args[0] === "-c" && args[1] === 'command -v "$1" >/dev/null 2>&1') return { status: 0 };
		if (file === "where") return { status: 0 };
		if (file === "systemctl" && args.join(" ") === "--user show-environment") return { status: 0 };
		if (file === "systemd-run" && args.at(-1) === "/usr/bin/true") return { status: 0 };
		if (file === "systemctl" && args[0] === "--user" && (args[1] === "stop" || args[1] === "kill")) {
			const fails = args[1] === "stop" ? options.stopFails : options.killFails;
			return { status: fails ? 1 : 0, stderr: fails ? "fixture_systemctl.exit=1" : "" };
		}
		if (file === "ps") return { status: 0, stdout: "Mon Jan  1 00:00:00 2024 fixture-child\n" };
		return forbidden(file, args);
	};
	const procRead = (path: string): string => {
		probeCalls.push({ file: path, args: [] });
		if (path === `/proc/${fixturePid}/comm`) return "fixture-child\n";
		if (path === `/proc/${fixturePid}/stat`) return `${fixturePid} (fixture-child) S ${Array(18).fill("0").join(" ")} 12345 0\n`;
		return forbidden("unexpected proc read", path);
	};
	const readFileSync = (path: filesystem.PathOrFileDescriptor, ...args: unknown[]) => {
		if (typeof path === "string" && path.startsWith("/proc/")) return procRead(path);
		return Reflect.apply(originalReadFileSync, filesystem, [path, ...args]);
	};
	const heldProcReads: (() => void)[] = [];
	const readFile = async (path: string, ...args: unknown[]) => {
		if (typeof path === "string" && path.startsWith("/proc/")) {
			if (options.deferProcReads) await new Promise<void>((resolve) => heldProcReads.push(resolve));
			return procRead(path);
		}
		return await Reflect.apply(originalReadFile, filesystemPromises, [path, ...args]);
	};
	const heldAppends: (() => void)[] = [];
	const appendFile = async (...args: unknown[]) => {
		if (options.deferAppends) await new Promise<void>((resolve) => heldAppends.push(resolve));
		return await Reflect.apply(originalAppendFile, filesystemPromises, args);
	};
	// Asynchronous probes answer through execFile's callback.
	const execFile = (file: string, args: string[], _options: unknown, callback: (error: Error | null, stdout: string, stderr: string) => void) => {
		probeCalls.push({ file, args });
		const answer = (stdout: string) => queueMicrotask(() => callback(null, stdout, ""));
		if (file === "ps") answer("Mon Jan  1 00:00:00 2024 fixture-child\n");
		else if (file === "systemctl" && args.join(" ") === "--user show-environment") answer("");
		else if (file === "systemctl" && args.slice(0, 3).join(" ") === "--user is-active --quiet") answer("");
		else return forbidden(file, args);
		return new FakeChild();
	};
	interface Timer { id: number; kind: "timeout" | "interval"; callback: () => void; ms: number; unref(): void }
	const timers = new Map<number, Timer>();
	const timerEvents: { action: string; kind: string; ms: number }[] = [];
	let timerSequence = 0;
	const schedule = (kind: Timer["kind"], callback: () => void, ms: number): Timer => {
		const timer = { id: ++timerSequence, kind, callback, ms, unref() {} };
		timers.set(timer.id, timer);
		timerEvents.push({ action: "set", kind, ms });
		return timer;
	};
	const clear = (timer: Timer) => {
		if (!timer) return;
		timerEvents.push({ action: "clear", kind: timer.kind, ms: timer.ms });
		timers.delete(timer.id);
	};
	process.kill = kill as typeof process.kill;
	Date.now = () => fixtureNow;
	Bun.spawn = forbidden as typeof Bun.spawn;
	Bun.spawnSync = forbidden as typeof Bun.spawnSync;
	globalThis.setTimeout = ((cb: () => void, ms: number) => schedule("timeout", cb, ms)) as unknown as typeof setTimeout;
	globalThis.setInterval = ((cb: () => void, ms: number) => schedule("interval", cb, ms)) as unknown as typeof setInterval;
	globalThis.clearTimeout = clear as unknown as typeof clearTimeout;
	globalThis.clearInterval = clear as unknown as typeof clearInterval;
	const childModule = { spawn, spawnSync, ChildProcess: FakeChild, exec: forbidden, execSync: forbidden, execFile, execFileSync: forbidden, fork: forbidden };
	Object.assign(nativeChildProcess, childModule);
	syncBuiltinESMExports();
	mock.module("node:child_process", () => childModule);
	mock.module("child_process", () => childModule);
	mock.module("node:fs", () => ({ ...filesystem, readFileSync }));
	mock.module("node:fs/promises", () => ({ ...filesystemPromises, readFile, appendFile }));
	const actual = await import("node:child_process");
	const alias = await import("child_process");
	const actualFs = await import("node:fs");
	const actualFsPromises = await import("node:fs/promises");
	const intercepted = {
		processModule: Object.entries(childModule).every(([name, value]) => Reflect.get(actual, name) === value && Reflect.get(alias, name) === value && Reflect.get(nativeChildProcess, name) === value),
		kill: process.kill === kill, readFileSync: actualFs.readFileSync === readFileSync, readFile: actualFsPromises.readFile === readFile,
		appendFile: actualFsPromises.appendFile === appendFile,
		bunSpawn: Bun.spawn === forbidden, bunSpawnSync: Bun.spawnSync === forbidden,
	};
	if (Object.values(intercepted).some((value) => !value)) {
		throw new Error(`spawn_fixture.interception=${JSON.stringify(intercepted)}\nExtension actions are refused.`);
	}
	return {
		signals, childSignals, spawns, syncCalls, probeCalls, unexpected, children, timerEvents,
		activeTimers: () => [...timers.values()].map(({ kind, ms }) => ({ kind, ms })),
		heldProcReads: () => heldProcReads.length,
		releaseProcReads() { for (const release of heldProcReads.splice(0)) release(); },
		heldAppends: () => heldAppends.length,
		releaseAppends() { for (const release of heldAppends.splice(0)) release(); },
		fireTimeout(ms: number) {
			const matches = [...timers.values()].filter((timer) => timer.kind === "timeout" && timer.ms === ms);
			if (matches.length !== 1) throw new Error(`spawn_fixture.timer_count=${matches.length}\ndelay_ms=${ms}`);
			timers.delete(matches[0]!.id);
			matches[0]!.callback();
		},
		restore() {
			for (const child of children) { child.stdout.destroy(); child.stderr.destroy(); child.removeAllListeners(); }
			timers.clear();
			process.kill = originalKill;
			Date.now = originalNow;
			Object.assign(globalThis, originalTimers);
			Object.assign(Bun, originalBun);
			Object.assign(nativeChildProcess, originalChildModule);
			syncBuiltinESMExports();
		},
	};
}
