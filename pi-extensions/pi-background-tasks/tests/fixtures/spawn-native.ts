import { mock } from "bun:test";
import nativeChildProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { EventEmitter } from "node:events";
import * as filesystem from "node:fs";
import { PassThrough } from "node:stream";

export const fixturePid = 4242;
export const fixtureNow = 1_700_000_000_000;

export async function interceptNativeEffects(options: { stopFails?: boolean; killFails?: boolean; signalGone?: boolean } = {}) {
	const signals: { pid: number; signal: unknown }[] = [];
	const childSignals: unknown[] = [];
	const spawns: { file: string; args: string[]; options: Record<string, unknown> }[] = [];
	const syncCalls: { file: string; args: string[] }[] = [];
	const unexpected: string[] = [];
	const children: FakeChild[] = [];
	const originalChildModule = { ...nativeChildProcess };
	const originalReadFileSync = filesystem.readFileSync;
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
	const readFileSync = (path: filesystem.PathOrFileDescriptor, ...args: unknown[]) => {
		if (typeof path === "string" && path.startsWith("/proc/")) {
			if (path === `/proc/${fixturePid}/comm`) return "fixture-child\n";
			if (path === `/proc/${fixturePid}/stat`) return `${fixturePid} (fixture-child) S ${Array(18).fill("0").join(" ")} 12345 0\n`;
			return forbidden("unexpected proc read", path);
		}
		return Reflect.apply(originalReadFileSync, filesystem, [path, ...args]);
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
	const childModule = { spawn, spawnSync, ChildProcess: FakeChild, exec: forbidden, execSync: forbidden, execFile: forbidden, execFileSync: forbidden, fork: forbidden };
	Object.assign(nativeChildProcess, childModule);
	syncBuiltinESMExports();
	mock.module("node:child_process", () => childModule);
	mock.module("child_process", () => childModule);
	mock.module("node:fs", () => ({ ...filesystem, readFileSync }));
	const actual = await import("node:child_process");
	const alias = await import("child_process");
	const actualFs = await import("node:fs");
	const intercepted = {
		processModule: Object.entries(childModule).every(([name, value]) => Reflect.get(actual, name) === value && Reflect.get(alias, name) === value && Reflect.get(nativeChildProcess, name) === value),
		kill: process.kill === kill, readFileSync: actualFs.readFileSync === readFileSync, bunSpawn: Bun.spawn === forbidden, bunSpawnSync: Bun.spawnSync === forbidden,
	};
	if (Object.values(intercepted).some((value) => !value)) {
		throw new Error(`spawn_fixture.interception=${JSON.stringify(intercepted)}\nExtension actions are refused.`);
	}
	return {
		signals, childSignals, spawns, syncCalls, unexpected, children, timerEvents,
		activeTimers: () => [...timers.values()].map(({ kind, ms }) => ({ kind, ms })),
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
