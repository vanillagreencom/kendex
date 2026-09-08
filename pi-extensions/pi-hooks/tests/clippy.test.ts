import { expect, spyOn, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CONFIG_ID, installCarrier, type ListenerHandler, type SentCall, toolResultEvent, trusted, useIsolatedGitEnv } from "./harness.ts";

import * as cargo from "../extensions/cargo.ts";

useIsolatedGitEnv();

type TurnHandler = ListenerHandler;
type TurnHooks = { onToolResult: TurnHandler; onTurnEnd: TurnHandler; onTurnStart: TurnHandler; sent: SentCall[] };

function installTurnHandlers(): TurnHooks {
	const carrier = installCarrier();
	return {
		onToolResult: carrier.handler("tool_result"),
		onTurnEnd: carrier.handler("turn_end"),
		onTurnStart: carrier.handler("turn_start"),
		sent: carrier.sent,
	};
}

/** A project whose settings arm the end-of-turn check the fixtures above leave off. */
function initClippyProject(): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-hooks-clippy-"));
	mkdirSync(join(dir, ".pi"), { recursive: true });
	writeFileSync(join(dir, ".pi", "settings.json"), JSON.stringify({
		kendex: {
			extensionManager: {
				config: { [CONFIG_ID]: { enabled: true, taskCompletedCheck: true, sessionDriftCheck: false, clippyTimeoutMs: 4000 } },
			},
		},
	}));
	mkdirSync(join(dir, "src"), { recursive: true });
	writeFileSync(join(dir, "src", "lib.rs"), "pub fn answer() -> i32 { 42 }\n");
	return dir;
}

/** A cargo naming `root` as the workspace and failing clippy with one error line. FAKE_CLIPPY_EXIT and FAKE_CLIPPY_SILENT vary the run. */
function fakeClippyBin(dir: string, root: string): string {
	const bin = join(dir, "bin");
	mkdirSync(bin, { recursive: true });
	const cargo = join(bin, "cargo");
	writeFileSync(cargo, [
		// A `/bin/sh` shebang, not `/usr/bin/env`: these fixtures run with PATH
		// narrowed to this directory, so nothing else is there to look up.
		"#!/bin/sh",
		"set -eu",
		'if [ "$1" = "metadata" ]; then',
		`  printf '{"workspace_root":"%s"}' ${JSON.stringify(root)}`,
		"  exit 0",
		"fi",
		// A line no error filter recognises, so the run reads as unavailable
		// rather than as errors.
		'if [ "${FAKE_CLIPPY_SILENT:-}" = "1" ]; then',
		"  printf '%s\\n' 'warning: nothing an error filter matches'",
		"else",
		"  printf '%s\\n' 'error[E0425]: cannot find value nope in this scope'",
		"fi",
		'exit "${FAKE_CLIPPY_EXIT:-101}"',
		"",
	].join("\n"));
	chmodSync(cargo, 0o755);
	return bin;
}

async function onPath(bin: string, run: () => Promise<void>, knobs: { exit?: string; silent?: string } = {}): Promise<void> {
	const names = ["PATH", "FAKE_CLIPPY_EXIT", "FAKE_CLIPPY_SILENT"] as const;
	const saved = names.map((name) => process.env[name]);
	process.env.PATH = bin;
	process.env.FAKE_CLIPPY_EXIT = knobs.exit ?? "101";
	process.env.FAKE_CLIPPY_SILENT = knobs.silent ?? "0";
	try { await run(); } finally {
		for (const [index, name] of names.entries()) {
			if (saved[index] === undefined) delete process.env[name];
			else process.env[name] = saved[index];
		}
	}
}

async function editingTurn(hooks: TurnHooks, project: string, ctx: Record<string, unknown>): Promise<void> {
	await hooks.onToolResult(toolResultEvent("edit", { path: join(project, "src", "lib.rs") }), ctx);
	await hooks.onTurnEnd({}, ctx);
}

function expectSteered(call: SentCall): void {
	expect(call.options).toEqual({ triggerTurn: true });
	expect(call.message.customType).toBe("kendex-clippy");
	expect(call.message.display).toBe(false);
}

for (const row of [
	{ name: "headless errors", ui: false, code: "101", silent: "0", cargo: true, key: "clippy-errors=1" },
	{ name: "interactive errors", ui: true, code: "101", silent: "0", cargo: true, key: "clippy-errors=1" },
	{ name: "clean", ui: true, code: "0", silent: "0", cargo: true, key: undefined },
	{ name: "missing workspace", ui: false, code: "101", silent: "0", cargo: false, key: "clippy-workspace=" },
	{ name: "no error line", ui: false, code: "101", silent: "1", cargo: true, key: "clippy-exit=101" },
	{ name: "timed out", ui: false, code: "101", silent: "0", cargo: true, key: "clippy-timeout-ms=3000" },
]) {
	test(`clippy reports ${row.name}`, async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const notices: string[] = [];
		const timeout = row.name === "timed out" ? spyOn(cargo, "runWorkspaceClippy").mockReturnValue({ exitCode: -1, stdout: "", stderr: "", timedOut: true }) : undefined;
		try {
			const bin = row.cargo ? fakeClippyBin(cargoRoot, project) : cargoRoot;
			await onPath(bin, async () => {
				const hooks = installTurnHandlers();
				await editingTurn(hooks, project, trusted(project, row.ui ? {
					hasUI: true, ui: { notify: (message: string) => notices.push(message) },
				} : {}));
				expect(hooks.sent).toHaveLength(row.key === undefined ? 0 : 1);
				expect(notices).toHaveLength(row.ui && row.key !== undefined ? 1 : 0);
				if (row.key === undefined) return;
				const call = hooks.sent[0]!;
				expectSteered(call);
				expect(call.message.content.split("\n")[0]).toBe(row.key + (row.cargo ? "" : project));
				if (row.key === "clippy-errors=1") expect(call.message.content).toContain("error[E0425]");
				if (row.ui) expect(notices).toEqual([call.message.content]);
			}, { exit: row.code, silent: row.silent });
		} finally {
			timeout?.mockRestore();
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});
}

for (const row of [
	{ name: "lookup recovery", turns: ["missing", "edit"], keys: ["clippy-workspace=", "clippy-errors=1"] },
	{ name: "repeated failure", turns: ["edit", "edit", "edit"], keys: ["clippy-errors=1", "clippy-errors=1", "clippy-errors=1"] },
	{ name: "untouched turn resets", turns: ["edit", "untouched"], keys: ["clippy-errors=1"] },
]) {
	test(`clippy lifecycle: ${row.name}`, async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const emptyBin = join(cargoRoot, "empty");
		mkdirSync(emptyBin);
		try {
			const hooks = installTurnHandlers();
			const ctx = trusted(project);
			const bin = fakeClippyBin(cargoRoot, project);
			let reports = 0;
			for (const turn of row.turns) {
				await hooks.onTurnStart({}, ctx);
				await onPath(turn === "missing" ? emptyBin : bin, async () => {
					if (turn === "untouched") await hooks.onTurnEnd({}, ctx);
					else await editingTurn(hooks, project, ctx);
				});
				if (turn !== "untouched") reports++;
				expect(hooks.sent).toHaveLength(reports);
				for (const call of hooks.sent) expectSteered(call);
			}
			expect(hooks.sent.map((call) => call.message.content.split("\n")[0])).toEqual(row.keys.map((key) => key === "clippy-workspace=" ? key + project : key));
			if (row.name === "repeated failure") expect(hooks.sent[2]?.message.content).toBe(hooks.sent[0]?.message.content);
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});
}
