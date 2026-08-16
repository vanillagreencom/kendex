import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { driftCheckArgs, driftMessage, runDriftCheck } from "../extensions/drift-check.ts";
import piHooks from "../extensions/hooks.ts";

type SessionStartHandler = (
	event: { type: "session_start"; reason: string },
	ctx: Record<string, unknown>,
) => Promise<unknown>;

/** Fake vstack that records argv, prints FAKE_OUT on stderr, exits FAKE_RC. */
function fakeVstack(root: string): { binary: string; argsLog: string } {
	const binary = join(root, "vstack");
	const argsLog = join(root, "args.log");
	writeFileSync(
		binary,
		`#!/usr/bin/env bash
printf '%s\\n' "$*" >>"${argsLog}"
if [ -n "\${FAKE_OUT:-}" ]; then printf '%s\\n' "$FAKE_OUT" >&2; fi
exit "\${FAKE_RC:-0}"
`,
	);
	chmodSync(binary, 0o755);
	return { binary, argsLog };
}

async function withFake<T>(rc: string, out: string, run: (paths: { binary: string; argsLog: string; root: string }) => Promise<T>): Promise<T> {
	const root = mkdtempSync(join(tmpdir(), "pi-hooks-drift-"));
	const paths = fakeVstack(root);
	const oldRc = process.env.FAKE_RC;
	const oldOut = process.env.FAKE_OUT;
	process.env.FAKE_RC = rc;
	process.env.FAKE_OUT = out;
	try {
		return await run({ ...paths, root });
	} finally {
		if (oldRc === undefined) delete process.env.FAKE_RC;
		else process.env.FAKE_RC = oldRc;
		if (oldOut === undefined) delete process.env.FAKE_OUT;
		else process.env.FAKE_OUT = oldOut;
		rmSync(root, { recursive: true, force: true });
	}
}

const REPORT = "vstack drift — project scope:\n  1 outdated — run `vstack refresh` to update:\n    ! orch (skill)";

describe("drift-check classification", () => {
	test("exit 0 is clean and silent", async () => {
		await withFake("0", "", async ({ binary, root, argsLog }) => {
			const result = await runDriftCheck(root, { includeAvailable: true, timeoutMs: 5000, binary });
			expect(result).toEqual({ kind: "clean" });
			expect(driftMessage(result)).toBeUndefined();
			expect(Bun.file(argsLog).text()).resolves.toBe("check --quiet\n");
		});
	});

	test("exit 1 relays the report verbatim", async () => {
		await withFake("1", REPORT, async ({ binary, root }) => {
			const result = await runDriftCheck(root, { includeAvailable: true, timeoutMs: 5000, binary });
			expect(result).toEqual({ kind: "drift", report: REPORT });
			expect(driftMessage(result)).toBe(REPORT);
		});
	});

	test("exit 2 is a failure that names the exit code and keeps the diagnostic", async () => {
		await withFake("2", "Error: loading lock file", async ({ binary, root }) => {
			const result = await runDriftCheck(root, { includeAvailable: true, timeoutMs: 5000, binary });
			expect(result.kind).toBe("failed");
			const message = driftMessage(result) ?? "";
			expect(message).toContain("vstack check could not run (exit 2)");
			expect(message).toContain("Error: loading lock file");
		});
	});

	test("a missing binary is unavailable and says so in one line", async () => {
		const root = mkdtempSync(join(tmpdir(), "pi-hooks-drift-missing-"));
		try {
			const result = await runDriftCheck(root, { includeAvailable: true, timeoutMs: 5000, binary: join(root, "no-such-vstack") });
			expect(result).toEqual({ kind: "unavailable" });
			expect(driftMessage(result)).toBe("vstack drift check skipped: vstack is not on PATH");
		} finally {
			rmSync(root, { recursive: true, force: true });
		}
	});

	test("an unusable cwd is named rather than blamed on a missing binary", async () => {
		const root = mkdtempSync(join(tmpdir(), "pi-hooks-drift-cwd-"));
		const missing = join(root, "gone");
		try {
			const result = await runDriftCheck(missing, { includeAvailable: true, timeoutMs: 5000, binary: "vstack" });
			expect(result).toEqual({ kind: "unusable-cwd", cwd: missing });
			expect(driftMessage(result)).toBe(
				`vstack check could not run: project directory ${missing} is not accessible; drift status unknown`,
			);
			// Control: the same call in a real directory reaches the binary,
			// so the guard is not swallowing every run.
			await withFake("0", "", async ({ binary, root: real }) => {
				expect(await runDriftCheck(real, { includeAvailable: true, timeoutMs: 5000, binary })).toEqual({ kind: "clean" });
			});
		} finally {
			rmSync(root, { recursive: true, force: true });
		}
	});

	test("a cwd that exists but cannot be entered is named too", async () => {
		if (process.getuid?.() === 0) {
			// Root ignores the permission bits this fixture relies on.
			return;
		}
		const root = mkdtempSync(join(tmpdir(), "pi-hooks-drift-perm-"));
		const locked = join(root, "locked");
		mkdirSync(locked);
		chmodSync(locked, 0o000);
		try {
			const result = await runDriftCheck(locked, { includeAvailable: true, timeoutMs: 5000, binary: "vstack" });
			expect(result).toEqual({ kind: "unusable-cwd", cwd: locked });
			expect(driftMessage(result)).toContain("is not accessible; drift status unknown");
		} finally {
			chmodSync(locked, 0o700);
			rmSync(root, { recursive: true, force: true });
		}
	});

	test("includeAvailable=false passes --no-available", () => {
		expect(driftCheckArgs({ includeAvailable: false })).toEqual(["check", "--quiet", "--no-available"]);
		expect(driftCheckArgs({ includeAvailable: true })).toEqual(["check", "--quiet"]);
	});
});

describe("session_start wiring", () => {
	type SessionStartHandlerSync = (
		event: { type: "session_start"; reason: string },
		ctx: Record<string, unknown>,
	) => unknown;

	function install(): { handler: SessionStartHandlerSync; sent: unknown[] } {
		let handler: SessionStartHandlerSync | undefined;
		const sent: unknown[] = [];
		const pi = {
			on(event: string, cb: SessionStartHandlerSync) {
				if (event === "session_start") handler = cb;
			},
			sendMessage(message: unknown, options: unknown) {
				sent.push({ message, options });
			},
		};
		piHooks(pi as never);
		if (!handler) throw new Error("session_start handler was not registered");
		return { handler, sent };
	}

	/** The handler is fire-and-forget: wait for `sent` to reach `n`, or ~2s. */
	async function waitForSent(sent: unknown[], n: number): Promise<void> {
		for (let i = 0; i < 100 && sent.length < n; i++) await new Promise((r) => setTimeout(r, 20));
	}

	/** Enough time for a spawned check to have landed if it were going to. */
	async function grace(): Promise<void> {
		await new Promise((r) => setTimeout(r, 300));
	}

	/** Isolate every settings source: HOME → temp, project pinned to enabled. */
	async function withIsolatedSettings<T>(root: string, run: () => Promise<T>): Promise<T> {
		const home = join(root, "home");
		mkdirSync(join(home, ".pi", "agent"), { recursive: true });
		mkdirSync(join(root, ".pi"), { recursive: true });
		writeFileSync(join(root, ".pi", "settings.json"), JSON.stringify({
			vstack: { extensionManager: { config: { "@vanillagreen/pi-hooks": { enabled: true, sessionDriftCheck: true, sessionDriftAvailable: true } } } },
		}));
		const oldHome = process.env.HOME;
		process.env.HOME = home;
		try {
			return await run();
		} finally {
			if (oldHome === undefined) delete process.env.HOME;
			else process.env.HOME = oldHome;
		}
	}

	test("drift is appended to context without triggering a turn or blocking start; reload, resume, and clean are silent", async () => {
		await withFake("1", REPORT, async ({ root }) => {
			const oldPath = process.env.PATH;
			process.env.PATH = `${root}:${oldPath ?? ""}`;
			try {
				await withIsolatedSettings(root, async () => {
					const ctx = { cwd: root, isProjectTrusted: () => true };
					const { handler, sent } = install();
					const returned = handler({ type: "session_start", reason: "startup" }, ctx);
					expect(returned).toBeUndefined();
					expect(sent).toHaveLength(0);
					await waitForSent(sent, 1);
					expect(sent).toEqual([
						{
							message: { customType: "vstack-drift", content: REPORT, display: true },
							options: { triggerTurn: false },
						},
					]);

					for (const reason of ["reload", "resume"]) {
						handler({ type: "session_start", reason }, ctx);
						await grace();
						expect(sent).toHaveLength(1);
					}

					process.env.FAKE_RC = "0";
					handler({ type: "session_start", reason: "startup" }, ctx);
					await grace();
					expect(sent).toHaveLength(1);
				});
			} finally {
				if (oldPath === undefined) delete process.env.PATH;
				else process.env.PATH = oldPath;
			}
		});
	});
});
