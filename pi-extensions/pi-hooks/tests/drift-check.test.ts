import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import type { DriftCheckResult } from "../extensions/drift-check.ts";
// Controls rerun these assertions against a planted copy, never the live file.
const { driftMessage, runDriftCheck } = await import(process.env.DRIFT_UNDER_TEST ?? "../extensions/drift-check.ts") as typeof import("../extensions/drift-check.ts");
import { withFake } from "./drift-fixture.ts";
import { runGit, useIsolatedGitEnv } from "./harness.ts";

useIsolatedGitEnv();

// kendex check produces these exit/report pairs. Report bytes are data from
// that command; the carrier owns only the diagnostic key above them.
for (const row of [
	{ code: 0, report: "", result: { kind: "clean" }, key: undefined },
	{ code: 1, report: "outdated=orch", result: { kind: "drift" }, key: "outdated=orch" },
	{ code: 1, report: "source comparison needed:\n  skill 'orch': source changed since evaluation; not yet re-evaluated\nNext: kendex refresh --scope project --yes in this checkout to refresh project packages.", result: { kind: "drift" }, key: "source comparison needed:" },
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
			expect(readFileSync(argsLog, "utf8")).toBe("check --quiet --report-only\n");
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

// crates/core/src/drift/report/render.rs::render_plain produces these report
// forms. The rule's prohibition is not actionable advice: assertions judge
// the report below that rule line, not the command names in the prohibition.
const laneReports = [
	{ name: "safe", code: 1, report: "source unreachable:\n  github.com/x/y: cannot lock ref", count: undefined },
	{ name: "refresh", code: 1, report: "source comparison needed:\n  skill 'orch': source changed since evaluation; not yet re-evaluated\nNext: kendex refresh --scope project --yes in this checkout to refresh project packages.", count: 1 },
	{ name: "updates", code: 1, report: "source comparison needed:\n  packages have not been compared with their sources \u2014 fix: kendex updates", count: 1 },
	{ name: "apply", code: 1, report: "stale:\n  'orch' does not match its source \u2014 fix: kendex apply", count: 1 },
	{ name: "remove", code: 1, report: "removed upstream:\n  skill 'orch': removed upstream: no replacement is declared: remove the installed copies and declaration \u2014 fix: kendex remove orch", count: 1 },
	{ name: "overflow", code: 1, report: "outdated:\n  skill 'orch': source changed \u2014 fix: kendex refresh\n  … 4 more \u2014 see: kendex check", count: 5 },
	{ name: "truncated", code: 1, report: "outdated:\n  skill 'orch': source changed \u2014 fix: kendex refresh\n… report truncated (3 more line(s)) \u2014 see: kendex check", count: 1 },
	{ name: "incomplete", code: 2, report: "source comparison needed:\n  skill 'orch': source changed since evaluation; not yet re-evaluated\nNext: kendex refresh --scope project --yes in this checkout to refresh project packages.", count: 1 },
	{ name: "clean", code: 0, report: "", count: undefined },
] as const;

for (const mode of ["linked", "marker", "main"] as const) {
	for (const row of laneReports) {
		test(`${mode} drift: ${row.name}`, async () => {
			await withFake(String(row.code), row.report, async ({ binary, root, argsLog }) => {
				runGit(["init", "-q", root], root);
				runGit(["config", "gc.auto", "0"], root);
				runGit(["config", "maintenance.auto", "false"], root);
				runGit(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], root);
				let cwd = root;
				if (mode === "linked") {
					cwd = join(root, "linked");
					runGit(["worktree", "add", "-q", "-b", "lane", cwd], root);
				}
				// lane-marker writes this root binding. A marker for another
				// root must not apply the lane rule to the base checkout.
				mkdirSync(join(root, ".git", "lane-mail"));
				writeFileSync(join(root, ".git", "lane-mail", "item"), `${mode === "main" ? join(root, "other") : cwd}\n`);
				const result = await runDriftCheck(cwd, { timeoutMs: 5000, binary });
				const message = driftMessage(result);
				expect(readFileSync(argsLog, "utf8")).toBe("check --quiet --report-only\n");
				if (mode === "main") {
					// The must-fail control: the same advice remains actionable
					// outside a lane. Nothing rewrites main-checkout output.
					expect(message).toBe(row.code === 0 ? undefined : row.code === 1 ? row.report : `kendex-drift-incomplete: exit=2\nSome drift status is unknown.\n${row.report}`);
				} else {
					expect(message?.split("\n")[0]).toBe("session-drift-check: lane=1");
					const detail = message?.split("\n").slice(2).join("\n");
					const report = row.count === undefined ? row.report : `session-drift-check: drift-items=${row.count}${row.name === "truncated" ? "\nsession-drift-check: count=lower-bound" : ""}`;
					expect(detail).toBe(row.code === 2 ? `kendex-drift-incomplete: exit=2\nSome drift status is unknown.\n${report}` : report);
				}
			});
		});
	}
}

for (const fault of ["gitfile", "marker-directory"] as const) {
	test(`lane discovery failure: ${fault}`, async () => {
		await withFake("1", laneReports[1].report, async ({ binary, root, argsLog }) => {
			if (fault === "gitfile") writeFileSync(join(root, ".git"), "broken gitfile\n");
			else {
				runGit(["init", "-q", root], root);
				writeFileSync(join(root, ".git", "lane-mail"), "not a directory\n");
			}
			const result = await runDriftCheck(root, { timeoutMs: 5000, binary });
			expect(driftMessage(result)?.split("\n")[0]).toBe("session-drift-check: lane=unknown");
			expect(existsSync(argsLog)).toBe(false);
		});
	});
}
