import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ResourceControlSpawnPlan } from "../extensions/resource-control.js";
import { command } from "./fixtures/resource-control.js";

test.skipIf(process.platform !== "linux")("default systemd availability probe executes the required service arguments", () => {
	const rows = [
		{ name: "successful service probe includes properties and actual cwd", systemctlStatus: 0, systemdRunStatus: 0, probeRuns: true, available: true },
		{ name: "failed user manager probe prevents service probe", systemctlStatus: 1, systemdRunStatus: 0, probeRuns: false, available: false },
		{ name: "failed service probe rejects systemd plan", systemctlStatus: 0, systemdRunStatus: 1, probeRuns: true, available: false },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "systemd availability probe rows must not be empty").toBeGreaterThan(0);
	for (const row of rows) {
		const root = mkdtempSync(join(tmpdir(), "pi-bg-rc-probe-"));
		try {
			const bin = join(root, "bin");
			const log = join(root, "commands.jsonl");
			mkdirSync(bin);
			writeFileSync(log, "");
			const fakeCommand = fileURLToPath(new URL("./fixtures/resource-systemd-command.ts", import.meta.url));
			for (const name of ["systemctl", "systemd-run"]) {
				writeFileSync(join(bin, name), `#!${process.execPath}\nimport ${JSON.stringify(fakeCommand)};\n`, { mode: 0o755 });
			}
			const child = spawnSync(process.execPath, [fileURLToPath(new URL("./fixtures/resource-probe-child.ts", import.meta.url))], {
				cwd: root, encoding: "utf8", timeout: 15_000,
				env: {
					...process.env, PATH: bin, PI_CODING_AGENT_DIR: join(root, "pi"), PI_BG_TASK_DIR: join(root, "background"),
					RESOURCE_PROBE_LOG: log, RESOURCE_SYSTEMCTL_STATUS: String(row.systemctlStatus), RESOURCE_SYSTEMD_RUN_STATUS: String(row.systemdRunStatus),
				},
			});
			if (child.error || child.status !== 0) throw new Error(`resource-probe-exit=${child.status ?? "none"}\n${row.name}: ${child.error?.message ?? child.stderr}`);
			const result = JSON.parse(child.stdout) as { pid: number; plan: ResourceControlSpawnPlan };
			const calls = readFileSync(log, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
			const expectedCalls = [{ command: "systemctl", args: ["--user", "show-environment"] }];
			if (row.probeRuns) expectedCalls.push({
				command: "systemd-run",
				args: [
					"--user", "--wait", "--pipe", "--quiet", "--collect", `--unit=kendex-pi-bg-probe-${result.pid}-123456.service`,
					`--working-directory=${root}`, "--property=CPUWeight=25", "--property=IOWeight=50", "--property=Nice=12",
					"--property=IOSchedulingClass=best-effort", "--property=IOSchedulingPriority=6", "--", "/usr/bin/true",
				],
			});
			const expectedPlan = row.available ? {
				file: "systemd-run", warnings: [],
				metadata: { mode: "systemd-run", requestedMode: "systemd-run", unitName: "kendex-pi-bg-bg-7-123456.service" },
				args: [
					"--user", "--quiet", "--wait", "--pipe", "--collect", "--unit=kendex-pi-bg-bg-7-123456.service",
					"--working-directory=/tmp/work tree", "--property=CPUWeight=25", "--property=IOWeight=50", "--property=Nice=12",
					"--property=IOSchedulingClass=best-effort", "--property=IOSchedulingPriority=6", "--", "/bin/bash", "-lc", command,
				],
			} : { file: "/bin/bash", args: ["-lc", command], warnings: [expect.stringMatching(/^resourceControlMode=systemd-run(?:\s|$)/)] };
			expect({ calls, plan: result.plan }, row.name).toStrictEqual({ calls: expectedCalls, plan: expectedPlan });
		} finally {
			rmSync(root, { recursive: true, force: true });
		}
	}
}, 30_000);
