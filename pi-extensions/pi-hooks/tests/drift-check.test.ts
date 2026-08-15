import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
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

	test("a missing binary is unavailable and silent", async () => {
		const root = mkdtempSync(join(tmpdir(), "pi-hooks-drift-missing-"));
		try {
			const result = await runDriftCheck(root, { includeAvailable: true, timeoutMs: 5000, binary: join(root, "no-such-vstack") });
			expect(result).toEqual({ kind: "unavailable" });
			expect(driftMessage(result)).toBeUndefined();
		} finally {
			rmSync(root, { recursive: true, force: true });
		}
	});

	test("includeAvailable=false passes --no-available", () => {
		expect(driftCheckArgs({ includeAvailable: false })).toEqual(["check", "--quiet", "--no-available"]);
		expect(driftCheckArgs({ includeAvailable: true })).toEqual(["check", "--quiet"]);
	});
});

describe("session_start wiring", () => {
	function install(): { handler: SessionStartHandler; sent: unknown[] } {
		let handler: SessionStartHandler | undefined;
		const sent: unknown[] = [];
		const pi = {
			on(event: string, cb: SessionStartHandler) {
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

	test("drift is appended to context without triggering a turn; reload and clean are silent", async () => {
		await withFake("1", REPORT, async ({ root }) => {
			const oldPath = process.env.PATH;
			process.env.PATH = `${root}:${oldPath ?? ""}`;
			try {
				const { handler, sent } = install();
				await handler({ type: "session_start", reason: "startup" }, { cwd: root });
				expect(sent).toEqual([
					{
						message: { customType: "vstack-drift", content: REPORT, display: true },
						options: { triggerTurn: false },
					},
				]);

				await handler({ type: "session_start", reason: "reload" }, { cwd: root });
				expect(sent).toHaveLength(1);

				process.env.FAKE_RC = "0";
				await handler({ type: "session_start", reason: "startup" }, { cwd: root });
				expect(sent).toHaveLength(1);
			} finally {
				if (oldPath === undefined) delete process.env.PATH;
				else process.env.PATH = oldPath;
			}
		});
	});
});
