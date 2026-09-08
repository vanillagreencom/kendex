import { expect, test } from "bun:test";
import { stopResourceControlledTask, type ResourceControlMetadata, type ResourceControlStopResult } from "../extensions/resource-control.js";

test("resource stop selects the unit command and returns its result", () => {
	const unit = "kendex-pi-bg-bg-7.service";
	const systemd: ResourceControlMetadata = { mode: "systemd-run", requestedMode: "auto", unitName: unit };
	const rows: {
		name: string; metadata: ResourceControlMetadata; signal: NodeJS.Signals;
		runnerResult: { status: number | null; stderr?: string; error?: Error };
		expected: { result: ResourceControlStopResult; calls: { command: string; args: string[] }[] };
	}[] = [
		{
			name: "SIGTERM stops the persisted unit without blocking", metadata: systemd, signal: "SIGTERM", runnerResult: { status: 0 },
			expected: {
				result: { attempted: true, ok: true, command: "systemctl", args: ["--user", "stop", "--no-block", unit] },
				calls: [{ command: "systemctl", args: ["--user", "stop", "--no-block", unit] }],
			},
		},
		{
			name: "SIGKILL kills the persisted unit", metadata: systemd, signal: "SIGKILL", runnerResult: { status: 0 },
			expected: {
				result: { attempted: true, ok: true, command: "systemctl", args: ["--user", "kill", "--signal=SIGKILL", unit] },
				calls: [{ command: "systemctl", args: ["--user", "kill", "--signal=SIGKILL", unit] }],
			},
		},
		{
			name: "non systemd metadata does not run a unit command",
			metadata: { mode: "nice-ionice", requestedMode: "nice-ionice" }, signal: "SIGTERM", runnerResult: { status: 0 },
			expected: { result: { attempted: false, ok: false }, calls: [] },
		},
		{
			name: "failed unit command retains stderr", metadata: systemd, signal: "SIGTERM", runnerResult: { status: 1, stderr: "unit stop refused" },
			expected: {
				result: { attempted: true, ok: false, command: "systemctl", args: ["--user", "stop", "--no-block", unit], error: "unit stop refused" },
				calls: [{ command: "systemctl", args: ["--user", "stop", "--no-block", unit] }],
			},
		},
		{
			name: "runner error takes precedence over stderr", metadata: systemd, signal: "SIGKILL",
			runnerResult: { status: null, error: new Error("unit command could not start"), stderr: "less specific stderr" },
			expected: {
				result: { attempted: true, ok: false, command: "systemctl", args: ["--user", "kill", "--signal=SIGKILL", unit], error: "unit command could not start" },
				calls: [{ command: "systemctl", args: ["--user", "kill", "--signal=SIGKILL", unit] }],
			},
		},
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "resource stop rows must not be empty").toBeGreaterThan(0);
	for (const row of rows) {
		const calls: { command: string; args: string[] }[] = [];
		const result = stopResourceControlledTask(row.metadata, row.signal, (command, args) => {
			calls.push({ command, args: [...args] });
			return row.runnerResult;
		});
		const observedResult = {
			attempted: result.attempted, ok: result.ok,
			command: result.command, args: result.args, error: result.error,
		};
		expect({ result: observedResult, calls }, row.name).toStrictEqual({
			result: { command: undefined, args: undefined, error: undefined, ...row.expected.result }, calls: row.expected.calls,
		});
	}
});
