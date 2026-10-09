import { execFileSync, spawnSync } from "node:child_process";
import assert from "node:assert/strict";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

// Table deadlines include every child window plus a window for parent setup and cleanup.
// A `spawn-extension.ts` child costs a measured mean of 4322 ms on an ubuntu-latest CI runner, where
// one child exceeded a 10000 ms budget. 30000 ms is about 7x that mean and 3x the exceeded value.
export const SPAWN_FIXTURE_TIMEOUT_MS = 30_000;

/** Wait only for native asynchronous I/O the fixture cannot complete synchronously. */
export async function waitForSpawnEffects(done: () => boolean, label: string): Promise<void> {
	for (let waited = 0; waited < 5_000 && !done(); waited += 1) await Bun.sleep(1);
	assert.ok(done(), label);
}

export interface ComponentBenchmark {
	logBytes: number;
	tailChars: number;
	commandChars: number;
	phases: { name: string; frames: number; wholeLogReads: number; syncReads: number; asyncReads: number; bytes: number; syncOpens: number; asyncOpens: number; commandWraps: number; maxFrameMs: number; maxStepMs: number }[];
}

/** Hold the operation bound separately from timing so a fast cache bypass still fails. */
export function assertComponentBenchmarkBounds(result: ComponentBenchmark): void {
	assert.equal(result.logBytes, 50_000_000);
	assert.equal(result.tailChars, 12_000);
	const rows = [
		// Three UTF-8 bytes per UTF-16 unit, plus one for a split surrogate pair.
		{ name: "steady", frames: 30, reads: 1, bytes: 36_001, wraps: 1 },
		{ name: "expanded", frames: 10, reads: 0, bytes: 0, wraps: 0 },
		{ name: "width", frames: 10, reads: 0, bytes: 0, wraps: 1 },
		{ name: "content", frames: 10, reads: 0, bytes: 0, wraps: 1 },
		{ name: "theme", frames: 10, reads: 0, bytes: 0, wraps: 1 },
		{ name: "second", frames: 1, reads: 1, bytes: 11, wraps: 1 },
		{ name: "return", frames: 1, reads: 0, bytes: 0, wraps: 1 },
	];
	assert.equal(result.phases.length, rows.length);
	for (const [index, row] of rows.entries()) {
		const phase = result.phases[index];
		assert.deepEqual({ name: phase.name, frames: phase.frames, wholeLogReads: phase.wholeLogReads, syncReads: phase.syncReads, syncOpens: phase.syncOpens, asyncOpens: phase.asyncOpens, reads: phase.asyncReads, bytes: phase.bytes, wraps: phase.commandWraps },
			{ name: row.name, frames: row.frames, wholeLogReads: 0, syncReads: 0, syncOpens: 0, asyncOpens: row.frames, reads: row.reads, bytes: row.bytes, wraps: row.wraps }, `component operations: ${row.name}`);
		// Each step must finish before the dashboard's one-second refresh interval.
		assert.ok(phase.maxStepMs < 1_000, `component step: ${row.name} ${phase.maxStepMs} ms`);
	}
}

export function runSpawnFixture(fixture: string, input: Record<string, unknown>, mutation?: { file: string; from: string; to: string }, sourceRef?: string): unknown {
	const scratch = resolve(import.meta.dir, "../../../..", "tmp");
	mkdirSync(scratch, { recursive: true });
	const root = realpathSync(mkdtempSync(join(scratch, "spawn-hardening-")));
	try {
		for (const name of [".pi", "home", "agent", "logs"]) mkdirSync(join(root, name));
		writeFileSync(join(root, "agent", "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-background-tasks": {
			showWidget: false, resourceControlEnabled: input.resource === true, resourceControlMode: "systemd-run", forceKillGraceMs: 5000,
		} } } } }));
		let entry = join(import.meta.dir, fixture);
		if (mutation || sourceRef) {
			const copy = join(root, "package");
			cpSync(resolve(import.meta.dir, "../.."), copy, { recursive: true });
			if (sourceRef) {
				const prefix = "pi-extensions/pi-background-tasks/extensions/";
				const gitOptions = { cwd: resolve(import.meta.dir, "../../../.."), env: { PATH: process.env.PATH }, encoding: "utf8" as const };
				const paths = execFileSync("git", ["ls-tree", "-r", "--name-only", sourceRef, "--", prefix], gitOptions).trim().split("\n");
				if (paths.length < 2 || !paths.includes(`${prefix}background-tasks.ts`) || !paths.includes(`${prefix}dashboard.ts`)) throw new Error("baseline extension discovery is incomplete");
				rmSync(join(copy, "extensions"), { recursive: true });
				for (const path of paths) {
					const target = join(copy, "extensions", path.slice(prefix.length));
					mkdirSync(resolve(target, ".."), { recursive: true });
					writeFileSync(target, execFileSync("git", ["show", `${sourceRef}:${path}`], gitOptions));
				}
			}
			if (mutation) {
				const file = join(copy, mutation.file);
				const source = readFileSync(file, "utf8");
				if (source.split(mutation.from).length !== 2) throw new Error("must-fail source match is not unique");
				const changed = source.replace(mutation.from, mutation.to);
				if (source === changed) throw new Error("must-fail source did not change");
				writeFileSync(file, changed);
			}
			entry = join(copy, "tests/fixtures", fixture);
		}
		const child = spawnSync(process.execPath, ["--no-install", entry], {
			cwd: root,
			env: { PATH: process.env.PATH, HOME: join(root, "home"), USERPROFILE: join(root, "home"), PI_CODING_AGENT_DIR: join(root, "agent"), PI_BG_TASK_DIR: join(root, "logs"), PI_BG_TASK_DIAGNOSTIC_LOG: join(root, "diagnostics.log") },
			input: JSON.stringify(input), encoding: "utf8", timeout: SPAWN_FIXTURE_TIMEOUT_MS, killSignal: "SIGKILL", maxBuffer: 2_000_000,
		});
		if (child.error) throw new Error(`spawn_fixture.spawn_error=${child.error.code ?? child.error.name}\n${child.error.message}\n${child.stderr}`);
		if (child.status !== 0) throw new Error(`spawn_fixture.child_exit=${child.status ?? child.signal}\n${child.stderr}`);
		return JSON.parse(child.stdout);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}
