import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createOrphanWatcher } from "../extensions/orphan-watcher.js";
import {
	planResourceControlledSpawn,
	readResourceControlSettings,
	stopResourceControlledTask,
	type ResourceControlSettings,
} from "../extensions/resource-control.js";
import { restoredTaskFromSnapshot, taskSnapshot } from "../extensions/snapshot.js";
import type { LifecycleHooks } from "../extensions/lifecycle.js";
import type { BackgroundTaskSnapshot, ManagedTask } from "../extensions/types.js";

const OLD_PI_DIR = process.env.PI_CODING_AGENT_DIR;

function spawnInput(overrides: Record<string, unknown> = {}) {
	return {
		command: "printf 'a b'; cat <<'EOF'\n$HOME && *\nEOF",
		cwd: "/tmp/work tree",
		shell: "/bin/bash",
		shellArgs: ["-lc"],
		taskId: "bg-7",
		now: 123456,
		...overrides,
	};
}

function settings(overrides: Partial<ResourceControlSettings> = {}): ResourceControlSettings {
	return {
		enabled: true,
		mode: "auto",
		applyToBgTask: true,
		applyToAutoBackground: true,
		cpuWeight: 100,
		ioWeight: 100,
		nice: 10,
		ioniceClass: "best-effort",
		ioniceLevel: 7,
		warnOnFallback: true,
		...overrides,
	};
}

function probes(systemd: boolean, commands: string[] = ["nice", "ionice", "systemd-run", "systemctl"]) {
	const available = new Set(commands);
	return {
		platform: "linux" as NodeJS.Platform,
		commandExists: (command: string) => available.has(command),
		userSystemdAvailable: () => systemd,
	};
}

function fakeSnapshot(overrides: Partial<BackgroundTaskSnapshot> = {}): BackgroundTaskSnapshot {
	return {
		command: "sleep 60",
		cwd: "/tmp/work",
		exitCode: null,
		exitNotified: false,
		expiresAt: null,
		id: "bg-rc",
		lastOutputAt: null,
		logFile: "/tmp/bg-rc.log",
		notifyOnExit: true,
		notifyOnOutput: false,
		outputBytes: 0,
		pid: 4242,
		procIdent: { comm: "systemd-run", pid: 4242, startToken: "start-4242" },
		sessionId: "session-A",
		startedAt: 1_700_000_000_000,
		status: "running",
		title: "sleep 60",
		updatedAt: 1_700_000_000_000,
		...overrides,
	};
}

function fakeManaged(overrides: Partial<ManagedTask> = {}): ManagedTask {
	return {
		...fakeSnapshot(),
		child: null,
		closed: false,
		forceKillTimer: null,
		lastAnnouncedLength: 0,
		matcher: null,
		notifyMode: "transition",
		output: "",
		outputTimer: null,
		pendingWakes: [],
		restored: true,
		stopReason: null,
		timeoutTimer: null,
		voidedWakeSequences: [],
		voidedWakes: new Set<number>(),
		wakeEvents: [],
		wakeSequence: 0,
		...overrides,
	};
}

function hooks(): LifecycleHooks {
	return {
		clearTaskTimers: () => {},
		persistSnapshots: () => {},
		refreshUi: () => {},
		rememberSnapshot: (task) => taskSnapshot(task),
		sendTaskEvent: () => true,
	};
}

afterEach(() => {
	if (OLD_PI_DIR === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = OLD_PI_DIR;
});

describe("resource-control settings", () => {
	test("defaults are disabled and safe", () => {
		const root = mkdtempSync(join(tmpdir(), "pi-bg-rc-default-"));
		process.env.PI_CODING_AGENT_DIR = join(root, "user");
		try {
			expect(readResourceControlSettings(root)).toEqual({
				enabled: false,
				mode: "auto",
				applyToBgTask: true,
				applyToAutoBackground: true,
				cpuWeight: 100,
				ioWeight: 100,
				nice: 10,
				ioniceClass: "best-effort",
				ioniceLevel: 7,
				warnOnFallback: true,
			});
		} finally {
			rmSync(root, { recursive: true, force: true });
		}
	});

	test("extension-manager config parses values and clamps numeric ranges", () => {
		const root = mkdtempSync(join(tmpdir(), "pi-bg-rc-config-"));
		const userDir = join(root, "user");
		process.env.PI_CODING_AGENT_DIR = userDir;
		mkdirSync(userDir, { recursive: true });
		writeFileSync(join(userDir, "settings.json"), JSON.stringify({
			vstack: {
				extensionManager: {
					config: {
						"@vanillagreen/pi-background-tasks": {
							resourceControlEnabled: true,
							resourceControlMode: "nice-ionice",
							resourceControlApplyToBgTask: false,
							resourceControlApplyToAutoBackground: false,
							resourceControlCpuWeight: 50_000,
							resourceControlIoWeight: "0",
							resourceControlNice: 42,
							resourceControlIoniceClass: "not-a-class",
							resourceControlIoniceLevel: -5,
							resourceControlWarnOnFallback: false,
						},
					},
				},
			},
		}));
		try {
			const parsed = readResourceControlSettings(root);
			expect(parsed.enabled).toBe(true);
			expect(parsed.mode).toBe("nice-ionice");
			expect(parsed.applyToBgTask).toBe(false);
			expect(parsed.applyToAutoBackground).toBe(false);
			expect(parsed.cpuWeight).toBe(10_000);
			expect(parsed.ioWeight).toBe(1);
			expect(parsed.nice).toBe(19);
			expect(parsed.ioniceClass).toBe("best-effort");
			expect(parsed.ioniceLevel).toBe(0);
			expect(parsed.warnOnFallback).toBe(false);
		} finally {
			rmSync(root, { recursive: true, force: true });
		}
	});
});

describe("resource-control spawn planning", () => {
	test("disabled controls preserve the original shell argv", () => {
		const input = spawnInput({ settings: settings({ enabled: false }), probes: probes(true) });
		const plan = planResourceControlledSpawn(input);
		expect(plan.file).toBe("/bin/bash");
		expect(plan.args).toEqual(["-lc", input.command]);
		expect(plan.metadata).toBeUndefined();
		expect(plan.warnings).toEqual([]);
	});

	test("systemd-run plan keeps command and cwd as argv, not shell-quoted text", () => {
		const input = spawnInput({ settings: settings({ cpuWeight: 25, ioWeight: 50, nice: 12, ioniceLevel: 6 }), probes: probes(true) });
		const plan = planResourceControlledSpawn(input);
		expect(plan.file).toBe("systemd-run");
		expect(plan.metadata).toEqual({ mode: "systemd-run", requestedMode: "auto", unitName: "vstack-pi-bg-bg-7-123456.scope", warning: undefined });
		expect(plan.args).toContain("--user");
		expect(plan.args).toContain("--scope");
		expect(plan.args).toContain("--wait");
		expect(plan.args).toContain("--collect");
		expect(plan.args).toContain("--unit=vstack-pi-bg-bg-7-123456.scope");
		expect(plan.args).toContain("--working-directory=/tmp/work tree");
		expect(plan.args).toContain("--property=CPUWeight=25");
		expect(plan.args).toContain("--property=IOWeight=50");
		expect(plan.args).toContain("--property=Nice=12");
		expect(plan.args).toContain("--property=IOSchedulingClass=best-effort");
		expect(plan.args).toContain("--property=IOSchedulingPriority=6");
		expect(plan.args.slice(-3)).toEqual(["/bin/bash", "-lc", input.command]);
		expect(plan.warnings).toEqual([]);
	});

	test("auto falls back to nice and ionice when user systemd scopes are unavailable", () => {
		const input = spawnInput({ settings: settings(), probes: probes(false) });
		const plan = planResourceControlledSpawn(input);
		expect(plan.file).toBe("nice");
		expect(plan.args).toEqual(["-n", "10", "ionice", "-c", "2", "-n", "7", "/bin/bash", "-lc", input.command]);
		expect(plan.metadata).toEqual({ mode: "nice-ionice", requestedMode: "auto", warning: plan.warnings[0] });
		expect(plan.warnings[0]).toContain("using nice/ionice fallback");
	});

	test("applyToAutoBackground=false leaves auto-backgrounded commands unwrapped", () => {
		const input = spawnInput({ origin: "auto-background", settings: settings({ applyToAutoBackground: false }), probes: probes(true) });
		const plan = planResourceControlledSpawn(input);
		expect(plan.file).toBe("/bin/bash");
		expect(plan.args).toEqual(["-lc", input.command]);
		expect(plan.metadata).toBeUndefined();
		expect(plan.warnings).toEqual([]);
	});

	test("explicit systemd-run mode no-ops instead of silently switching helpers", () => {
		const input = spawnInput({ settings: settings({ mode: "systemd-run" }), probes: probes(false) });
		const plan = planResourceControlledSpawn(input);
		expect(plan.file).toBe("/bin/bash");
		expect(plan.args).toEqual(["-lc", input.command]);
		expect(plan.metadata).toBeUndefined();
		expect(plan.warnings[0]).toContain("systemd-run requested");
	});

	test("nice-ionice mode degrades to nice-only when ionice is missing", () => {
		const input = spawnInput({ settings: settings({ mode: "nice-ionice", ioniceClass: "idle" }), probes: probes(false, ["nice"]) });
		const plan = planResourceControlledSpawn(input);
		expect(plan.file).toBe("nice");
		expect(plan.args).toEqual(["-n", "10", "/bin/bash", "-lc", input.command]);
		expect(plan.metadata?.mode).toBe("nice-ionice");
	});
});

describe("resource-control stop and restore semantics", () => {
	test("systemd scope stop persists enough metadata to stop actual workload", () => {
		const calls: { command: string; args: string[] }[] = [];
		const runner = (command: string, args: string[]) => {
			calls.push({ command, args });
			return { status: 0 };
		};
		const metadata = { mode: "systemd-run" as const, requestedMode: "auto" as const, unitName: "vstack-pi-bg-bg-7.scope" };
		expect(stopResourceControlledTask(metadata, "SIGTERM", runner)).toMatchObject({ attempted: true, ok: true });
		expect(stopResourceControlledTask(metadata, "SIGKILL", runner)).toMatchObject({ attempted: true, ok: true });
		expect(calls).toEqual([
			{ command: "systemctl", args: ["--user", "stop", "--no-block", "vstack-pi-bg-bg-7.scope"] },
			{ command: "systemctl", args: ["--user", "kill", "--signal=SIGKILL", "vstack-pi-bg-bg-7.scope"] },
		]);
	});

	test("non-systemd resource controls rely on existing process-group stop", () => {
		expect(stopResourceControlledTask({ mode: "nice-ionice", requestedMode: "nice-ionice" }, "SIGTERM")).toEqual({ attempted: false, ok: false });
	});

	test("restore keeps a systemd scope running when the unit is active even if wrapper pid probe is gone", () => {
		const restored = restoredTaskFromSnapshot(fakeSnapshot({
			resourceControl: { mode: "systemd-run", requestedMode: "auto", unitName: "vstack-pi-bg-bg-7.scope" },
		}), {
			sessionId: "session-A",
			identityProbe: () => null,
			unitActiveProbe: () => true,
			now: 1_700_000_001_000,
		});
		expect(restored.status).toBe("running");
		expect(restored.closed).toBe(false);
		expect(restored.exitNotified).toBe(false);
	});

	test("restore finalizes a running systemd task when the persisted unit is inactive", () => {
		const restored = restoredTaskFromSnapshot(fakeSnapshot({
			resourceControl: { mode: "systemd-run", requestedMode: "auto", unitName: "vstack-pi-bg-bg-7.scope" },
		}), {
			sessionId: "session-A",
			identityProbe: () => ({ comm: "systemd-run", pid: 4242, startToken: "start-4242" }),
			unitActiveProbe: () => false,
			now: 1_700_000_001_000,
		});
		expect(restored.status).toBe("stopped");
		expect(restored.closed).toBe(true);
		expect(restored.exitNotified).toBe(false);
		expect(restored.terminationReason).toBe("reconcile-on-restart");
	});

	test("orphan watcher checks active systemd units before pid identity", () => {
		const task = fakeManaged({
			resourceControl: { mode: "systemd-run", requestedMode: "auto", unitName: "vstack-pi-bg-bg-7.scope" },
		});
		const watcher = createOrphanWatcher({
			getTasks: () => [task],
			hooks: hooks(),
			identityProbe: () => null,
			unitActiveProbe: () => true,
		});
		expect(watcher.checkOnce()).toEqual({ finalized: 0 });
		expect(task.status).toBe("running");
	});
});
