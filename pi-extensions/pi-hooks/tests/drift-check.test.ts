import { expect, test } from "bun:test";
import { chmodSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { driftMessage, runDriftCheck, type DriftCheckResult } from "../extensions/drift-check.ts";
import { withFake } from "./drift-fixture.ts";

// kendex check produces these exit/report pairs. Report bytes are data from
// that command; the carrier owns only the diagnostic key above them.
for (const row of [
	{ code: 0, report: "", result: { kind: "clean" }, key: undefined },
	{ code: 1, report: "outdated=orch", result: { kind: "drift" }, key: "outdated=orch" },
	{ code: 1, report: "unevaluated=33", result: { kind: "drift" }, key: "unevaluated=33" },
	{ code: 2, report: "could not check:\n  manifest: expected a table", result: { kind: "incomplete" }, key: "kendex-drift-incomplete: exit=2" },
	{ code: 2, report: "could not check:\n  source: error: cannot lock ref", result: { kind: "incomplete" }, key: "kendex-drift-incomplete: exit=2" },
	{ code: 2, report: "", result: { kind: "failed", exitCode: 2 }, key: "kendex-drift-failed: exit=2" },
	{ code: 2, report: "Error: loading lock file", result: { kind: "failed", exitCode: 2 }, key: "kendex-drift-failed: exit=2" },
	{ code: 2, report: "error: unexpected argument '--bogus'", result: { kind: "failed", exitCode: 2 }, key: "kendex-drift-failed: exit=2" },
	{ code: 3, report: "fatal=kendex", result: { kind: "failed", exitCode: 3 }, key: "kendex-drift-failed: exit=3" },
	{ code: 3, report: "", result: { kind: "failed", exitCode: 3 }, key: "kendex-drift-failed: exit=3" },
] as const) {
	test(`check exit ${row.code}, report ${JSON.stringify(row.report)}`, async () => {
		await withFake(String(row.code), row.report, async ({ binary, root, argsLog }) => {
			const result = await runDriftCheck(root, { timeoutMs: 5000, binary });
			const expected = row.result.kind === "clean" ? row.result : { ...row.result, report: row.report };
			expect(result).toEqual(expected);
			expect(readFileSync(argsLog, "utf8")).toBe("check --quiet\n");
			const message = driftMessage(result);
			expect(message?.split("\n")[0]).toBe(row.key);
			if (result.kind === "drift") expect(message).toBe(row.report);
			else if (row.report !== "") expect(message?.endsWith(row.report)).toBe(true);
		});
	});
}

for (const row of [
	{ name: "missing binary", directory: "root", key: "kendex-drift-unavailable: command=kendex" },
	{ name: "missing cwd", directory: "missing", key: "drift-cwd=" },
	{ name: "unreadable cwd", directory: "locked", key: "drift-cwd=" },
] as const) {
	test.skipIf(row.directory === "locked" && process.getuid?.() === 0)(row.name, async () => {
		await withFake("0", "", async ({ root }) => {
			const cwd = row.directory === "root" ? root : join(root, row.directory);
			if (row.directory === "locked") { mkdirSync(cwd); chmodSync(cwd, 0o000); }
			try {
				const result = await runDriftCheck(cwd, { timeoutMs: 5000, binary: join(root, "absent") });
				const expected: DriftCheckResult = row.directory === "root" ? { kind: "unavailable" } : { kind: "unusable-cwd", cwd };
				expect(result).toEqual(expected);
				expect(driftMessage(result)?.split("\n")[0]).toBe(row.key + (row.directory === "root" ? "" : cwd));
			} finally {
				if (row.directory === "locked") chmodSync(cwd, 0o700);
			}
		});
	});
}
