import { spawnSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

/*
 * Real-process helpers. A command under test is a POSIX shell script the case
 * writes, so the manager's runner spawns, signals and kills a real process
 * tree. Children inherit `process.env`, which each suite pins (PATH, HOME,
 * PI_CODING_AGENT_DIR) in its own setup.
 */

/** Write an executable `/bin/sh` script at `path` and return the path. */
export function writeCommand(path: string, body: string): string {
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, `#!/bin/sh\n${body}\n`);
	chmodSync(path, 0o755);
	return path;
}

/** Whether `pid` names a running process; a zombie awaiting its reaper counts as gone. */
export function processAlive(pid: number): boolean {
	const ps = spawnSync("ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8", env: { PATH: process.env.PATH } });
	if (ps.error) throw ps.error;
	const state = ps.stdout.trim();
	return state.length > 0 && !state.startsWith("Z");
}

/**
 * Wait for `predicate`, polling every 20 ms. A real wait: the condition is a
 * child process reaching a point on its own clock.
 */
export async function waitFor(label: string, predicate: () => boolean, ms = 5_000): Promise<void> {
	const until = Date.now() + ms;
	while (!predicate()) {
		if (Date.now() > until) throw new Error(`wait-for: ${label} not reached within ${ms} ms`);
		await Bun.sleep(20);
	}
}

/** The pid a fake command wrote to `path` once it started. */
export async function startedPid(path: string): Promise<number> {
	await waitFor(`pid file ${path}`, () => existsSync(path) && readFileSync(path, "utf8").trim().length > 0);
	return Number(readFileSync(path, "utf8").trim());
}

/**
 * `promise`'s value, or `unsettled` once `ms` passes. A real wait: a mutant
 * control proves a run does NOT settle, which no clock injection can show.
 */
export async function settleWithin<T>(promise: Promise<T>, ms: number): Promise<T | "unsettled"> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	const bound = new Promise<"unsettled">((resolve) => { timer = setTimeout(() => resolve("unsettled"), ms); });
	try {
		return await Promise.race([promise, bound]);
	} finally {
		clearTimeout(timer);
	}
}

export interface SourceEdit { file: string; before: string; after: string }

const extensionsSource = join(import.meta.dir, "..", "..", "extensions");

/**
 * Copy `extensions/manager` into `dir` with each edit applied to exactly one
 * occurrence, for a must-fail control that runs the planted defect.
 */
export function mutantManager(dir: string, edits: SourceEdit[]): string {
	return copyWithEdits(join(extensionsSource, "manager"), dir, edits);
}

/** As `mutantManager`, for all of `extensions`: the entry and `manager/`. */
export function mutantExtensions(dir: string, edits: SourceEdit[]): string {
	return copyWithEdits(extensionsSource, dir, edits);
}

function copyWithEdits(source: string, dir: string, edits: SourceEdit[]): string {
	cpSync(source, dir, { recursive: true });
	for (const edit of edits) {
		const path = join(dir, edit.file);
		const source = readFileSync(path, "utf8");
		const count = source.split(edit.before).length - 1;
		if (count !== 1) throw new Error(`mutant-edit: ${edit.file} matches ${count} times, expected 1: ${edit.before}`);
		const changed = source.replace(edit.before, edit.after);
		if (changed === source) throw new Error(`mutant-edit: ${edit.file} unchanged`);
		writeFileSync(path, changed);
	}
	return dir;
}
