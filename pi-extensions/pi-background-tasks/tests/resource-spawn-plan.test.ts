import { expect, test } from "bun:test";
import { planResourceControlledSpawn, type ResourceControlSpawnInput, type ResourceControlSpawnPlan } from "../extensions/resource-control.js";
import { command, probes, settings, spawnInput } from "./fixtures/resource-control.js";

test("resource spawn plans retain complete argv, metadata and warnings", () => {
	const fallbackWarning = expect.stringMatching(/^resourceControlMode=auto(?:\s|$)/);
	const rows: { name: string; input: Partial<ResourceControlSpawnInput>; expected: ResourceControlSpawnPlan; systemdProbes: number; metadataWarningMatches?: boolean }[] = [
		{
			name: "disabled controls retain original shell argv",
			input: { settings: settings({ enabled: false }), probes: probes(true) },
			expected: { file: "/bin/bash", args: ["-lc", command], warnings: [] },
			systemdProbes: 0,
		},
		{
			name: "systemd service preserves properties cwd and multiline shell command",
			input: { settings: settings({ cpuWeight: 25, ioWeight: 50, nice: 12, ioniceLevel: 6 }), probes: probes(true) },
			expected: {
				file: "systemd-run",
				args: [
					"--user", "--quiet", "--wait", "--pipe", "--collect", "--unit=kendex-pi-bg-bg-7-123456.service",
					"--working-directory=/tmp/work tree", "--property=CPUWeight=25", "--property=IOWeight=50",
					"--property=Nice=12", "--property=IOSchedulingClass=best-effort", "--property=IOSchedulingPriority=6",
					"--", "/bin/bash", "-lc", command,
				],
				metadata: { mode: "systemd-run", requestedMode: "auto", unitName: "kendex-pi-bg-bg-7-123456.service", warning: undefined },
				warnings: [],
			},
			systemdProbes: 1,
		},
		{
			name: "auto mode falls back to nice and ionice",
			input: { settings: settings(), probes: probes(false) },
			expected: {
				file: "nice", args: ["-n", "10", "ionice", "-c", "2", "-n", "7", "/bin/bash", "-lc", command],
				metadata: { mode: "nice-ionice", requestedMode: "auto", warning: fallbackWarning }, warnings: [fallbackWarning],
			},
			systemdProbes: 1,
		},
		{
			name: "auto background opt out retains original shell argv",
			input: { origin: "auto-background", settings: settings({ applyToAutoBackground: false }), probes: probes(true) },
			expected: { file: "/bin/bash", args: ["-lc", command], warnings: [] },
			systemdProbes: 0,
		},
		{
			name: "unavailable explicit systemd mode retains shell with a warning",
			metadataWarningMatches: false,
			input: { settings: settings({ mode: "systemd-run" }), probes: probes(false) },
			expected: { file: "/bin/bash", args: ["-lc", command], warnings: [expect.stringMatching(/^resourceControlMode=systemd-run(?:\s|$)/)] },
			systemdProbes: 1,
		},
		{
			name: "nice ionice mode never asks the systemd probe",
			input: { settings: settings({ mode: "nice-ionice" }), probes: probes(true) },
			expected: {
				file: "nice", args: ["-n", "10", "ionice", "-c", "2", "-n", "7", "/bin/bash", "-lc", command],
				metadata: { mode: "nice-ionice", requestedMode: "nice-ionice", warning: undefined }, warnings: [],
			},
			systemdProbes: 0,
		},
		{
			name: "nice ionice mode uses nice alone when ionice is missing",
			input: { settings: settings({ mode: "nice-ionice", ioniceClass: "idle" }), probes: probes(false, ["nice"]) },
			expected: {
				file: "nice", args: ["-n", "10", "/bin/bash", "-lc", command],
				metadata: { mode: "nice-ionice", requestedMode: "nice-ionice", warning: undefined }, warnings: [],
			},
			systemdProbes: 0,
		},
		{
			name: "nice ionice mode on Windows retains shell with a warning",
			metadataWarningMatches: false,
			input: { settings: settings({ mode: "nice-ionice" }), probes: { ...probes(false), platform: "win32" } },
			expected: { file: "/bin/bash", args: ["-lc", command], warnings: [expect.stringMatching(/^resourceControlMode=nice-ionice(?:\s|$)/)] },
			systemdProbes: 0,
		},
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "resource spawn plan rows must not be empty").toBeGreaterThan(0);
	for (const row of rows) {
		let systemdProbes = 0;
		const rowProbes = row.input.probes;
		const countingProbes = rowProbes === undefined ? undefined : {
			...rowProbes,
			userSystemdAvailable: () => {
				systemdProbes += 1;
				return rowProbes.userSystemdAvailable?.() ?? false;
			},
		};
		const plan = planResourceControlledSpawn(spawnInput({ ...row.input, probes: countingProbes }));
		const metadata = plan.metadata;
		const observedPlan = {
			file: plan.file, args: plan.args, warnings: plan.warnings,
			metadata: metadata === undefined ? undefined : {
				mode: metadata.mode, requestedMode: metadata.requestedMode,
				unitName: metadata.unitName, warning: metadata.warning,
			},
		};
		expect({ plan: observedPlan, systemdProbes, metadataWarningMatches: plan.metadata?.warning === plan.warnings[0] }, row.name).toStrictEqual({
			plan: {
				...row.expected,
				metadata: row.expected.metadata === undefined ? undefined : { unitName: undefined, warning: undefined, ...row.expected.metadata },
			},
			systemdProbes: row.systemdProbes,
			metadataWarningMatches: row.metadataWarningMatches ?? true,
		});
	}
});
