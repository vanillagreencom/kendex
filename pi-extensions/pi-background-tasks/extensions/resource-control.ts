import { spawnSync } from "node:child_process";

import { runProbe, type ProbeRunner } from "./probes.js";
import { settingBoolean, settingEnum, settingNumber } from "./settings.js";

export const RESOURCE_CONTROL_MODES = ["auto", "systemd-run", "nice-ionice", "off"] as const;
export const RESOURCE_CONTROL_IONICE_CLASSES = ["realtime", "best-effort", "idle"] as const;

export type ResourceControlMode = typeof RESOURCE_CONTROL_MODES[number];
export type ResourceControlIoniceClass = typeof RESOURCE_CONTROL_IONICE_CLASSES[number];
export type ResourceControlAppliedMode = "systemd-run" | "nice-ionice";
export type ResourceControlOrigin = "bg_task" | "auto-background";

export interface ResourceControlSettings {
	enabled: boolean;
	mode: ResourceControlMode;
	applyToBgTask: boolean;
	applyToAutoBackground: boolean;
	cpuWeight: number;
	ioWeight: number;
	nice: number;
	ioniceClass: ResourceControlIoniceClass;
	ioniceLevel: number;
	warnOnFallback: boolean;
}

export interface ResourceControlMetadata {
	mode: ResourceControlAppliedMode;
	requestedMode: ResourceControlMode;
	unitName?: string;
	warning?: string;
}

export interface ResourceControlSpawnInput {
	command: string;
	cwd: string;
	shell: string;
	shellArgs: string[];
	taskId: string;
	now?: number;
	origin?: ResourceControlOrigin;
	settings?: ResourceControlSettings;
	probes?: ResourceControlProbes;
}

export interface ResourceControlSpawnPlan {
	file: string;
	args: string[];
	metadata?: ResourceControlMetadata;
	warnings: string[];
}

export interface ResourceControlProbes {
	platform?: NodeJS.Platform;
	commandExists?: (command: string) => boolean;
	userSystemdAvailable?: () => boolean;
}

export interface ResourceControlStopResult {
	attempted: boolean;
	ok: boolean;
	command?: string;
	args?: string[];
	error?: string;
}

type StopRunner = (command: string, args: string[]) => { status: number | null; error?: Error; stderr?: string | Buffer | null };

const DEFAULT_CPU_WEIGHT = 100;
const DEFAULT_IO_WEIGHT = 100;
const DEFAULT_NICE = 10;
const DEFAULT_IONICE_CLASS: ResourceControlIoniceClass = "best-effort";
const DEFAULT_IONICE_LEVEL = 7;
const SYSTEMCTL_TIMEOUT_MS = 2_000;
/** Succeeds only when the user's systemd manager answers on its bus. */
const SYSTEMD_USER_MANAGER_PROBE_ARGS = ["--user", "show-environment"];
const cachedUserSystemdRunnable = new Map<string, boolean>();

function finiteInt(value: number, fallback: number): number {
	return Number.isFinite(value) ? Math.round(value) : fallback;
}

function clampInt(value: number, min: number, max: number, fallback: number): number {
	return Math.min(max, Math.max(min, finiteInt(value, fallback)));
}

export function readResourceControlSettings(cwd?: string): ResourceControlSettings {
	return {
		enabled: settingBoolean("resourceControlEnabled", false, cwd),
		mode: settingEnum("resourceControlMode", RESOURCE_CONTROL_MODES, "auto", cwd),
		applyToBgTask: settingBoolean("resourceControlApplyToBgTask", true, cwd),
		applyToAutoBackground: settingBoolean("resourceControlApplyToAutoBackground", true, cwd),
		cpuWeight: clampInt(settingNumber("resourceControlCpuWeight", DEFAULT_CPU_WEIGHT, cwd), 1, 10_000, DEFAULT_CPU_WEIGHT),
		ioWeight: clampInt(settingNumber("resourceControlIoWeight", DEFAULT_IO_WEIGHT, cwd), 1, 10_000, DEFAULT_IO_WEIGHT),
		nice: clampInt(settingNumber("resourceControlNice", DEFAULT_NICE, cwd), -20, 19, DEFAULT_NICE),
		ioniceClass: settingEnum("resourceControlIoniceClass", RESOURCE_CONTROL_IONICE_CLASSES, DEFAULT_IONICE_CLASS, cwd),
		ioniceLevel: clampInt(settingNumber("resourceControlIoniceLevel", DEFAULT_IONICE_LEVEL, cwd), 0, 7, DEFAULT_IONICE_LEVEL),
		warnOnFallback: settingBoolean("resourceControlWarnOnFallback", true, cwd),
	};
}

function commandExists(command: string, platform: NodeJS.Platform): boolean {
	try {
		if (platform === "win32") {
			const result = spawnSync("where", [command], { stdio: "ignore", timeout: 1_000 });
			return result.status === 0;
		}
		const result = spawnSync("sh", ["-c", "command -v \"$1\" >/dev/null 2>&1", "sh", command], { stdio: "ignore", timeout: 1_000 });
		return result.status === 0;
	} catch {
		return false;
	}
}

function systemdProbeCacheKey(settings: ResourceControlSettings): string {
	return [settings.cpuWeight, settings.ioWeight, settings.nice, settings.ioniceClass, settings.ioniceLevel].join(":");
}

function systemdResourcePropertyArgs(settings: ResourceControlSettings): string[] {
	return [
		`--property=CPUWeight=${settings.cpuWeight}`,
		`--property=IOWeight=${settings.ioWeight}`,
		`--property=Nice=${settings.nice}`,
		`--property=IOSchedulingClass=${settings.ioniceClass}`,
		...(settings.ioniceClass === "idle" ? [] : [`--property=IOSchedulingPriority=${settings.ioniceLevel}`]),
	];
}

function userSystemdAvailable(commandProbe: (command: string) => boolean, platform: NodeJS.Platform, settings: ResourceControlSettings): boolean {
	if (platform !== "linux") return false;
	if (!commandProbe("systemd-run") || !commandProbe("systemctl")) return false;
	const cacheKey = systemdProbeCacheKey(settings);
	const cached = cachedUserSystemdRunnable.get(cacheKey);
	if (cached !== undefined) return cached;
	try {
		const result = spawnSync("systemctl", SYSTEMD_USER_MANAGER_PROBE_ARGS, { stdio: "ignore", timeout: 1_500 });
		if (result.status !== 0) {
			cachedUserSystemdRunnable.set(cacheKey, false);
			return false;
		}
		// Probe the exact transient-service shape used below. Older scope-based
		// plans accepted availability checks but failed at spawn time on hosts
		// where `--scope --wait` or scope-level Nice/IOScheduling properties are
		// rejected by systemd-run.
		const unitName = `kendex-pi-bg-probe-${process.pid}-${Date.now()}.service`;
		const probe = spawnSync("systemd-run", [
			"--user",
			"--wait",
			"--pipe",
			"--quiet",
			"--collect",
			`--unit=${unitName}`,
			`--working-directory=${process.cwd()}`,
			...systemdResourcePropertyArgs(settings),
			"--",
			"/usr/bin/true",
		], { stdio: "ignore", timeout: 3_000 });
		const ok = probe.status === 0;
		cachedUserSystemdRunnable.set(cacheKey, ok);
		return ok;
	} catch {
		cachedUserSystemdRunnable.set(cacheKey, false);
		return false;
	}
}

function platformFor(probes?: ResourceControlProbes): NodeJS.Platform {
	return probes?.platform ?? process.platform;
}

function commandProbeFor(probes: ResourceControlProbes | undefined, platform: NodeJS.Platform): (command: string) => boolean {
	return probes?.commandExists ?? ((command: string) => commandExists(command, platform));
}

function systemdProbeFor(probes: ResourceControlProbes | undefined, commandProbe: (command: string) => boolean, platform: NodeJS.Platform, settings: ResourceControlSettings): () => boolean {
	return probes?.userSystemdAvailable ?? (() => userSystemdAvailable(commandProbe, platform, settings));
}

function originApplies(settings: ResourceControlSettings, origin: ResourceControlOrigin): boolean {
	return origin === "auto-background" ? settings.applyToAutoBackground : settings.applyToBgTask;
}

function canUseNiceIonice(commandProbe: (command: string) => boolean, platform: NodeJS.Platform): boolean {
	if (platform === "win32") return false;
	return commandProbe("nice") || commandProbe("ionice");
}

function ioniceClassNumber(value: ResourceControlIoniceClass): string {
	if (value === "realtime") return "1";
	if (value === "idle") return "3";
	return "2";
}

function makeSystemdUnitName(taskId: string, now: number): string {
	const safe = `${taskId}-${now}`.replaceAll(/[^A-Za-z0-9_.:-]/g, "-").slice(0, 96) || "task";
	return `kendex-pi-bg-${safe}.service`;
}

function basePlan(input: ResourceControlSpawnInput): ResourceControlSpawnPlan {
	return { file: input.shell, args: [...input.shellArgs, input.command], warnings: [] };
}

function resolveMode(
	settings: ResourceControlSettings,
	origin: ResourceControlOrigin,
	probes: ResourceControlProbes | undefined,
): { mode: ResourceControlAppliedMode | "none"; warning?: string } {
	if (!settings.enabled || settings.mode === "off" || !originApplies(settings, origin)) return { mode: "none" };

	const platform = platformFor(probes);
	const hasCommand = commandProbeFor(probes, platform);
	const hasSystemd = systemdProbeFor(probes, hasCommand, platform, settings);
	const systemdOk = hasSystemd();
	const niceOk = canUseNiceIonice(hasCommand, platform);

	if (settings.mode === "systemd-run") {
		return systemdOk
			? { mode: "systemd-run" }
			: { mode: "none", warning: "resourceControlMode=systemd-run requested, but usable user systemd-run support was not detected; spawning without resource controls." };
	}

	if (settings.mode === "nice-ionice") {
		return niceOk
			? { mode: "nice-ionice" }
			: { mode: "none", warning: "resourceControlMode=nice-ionice requested, but nice/ionice helpers were not detected; spawning without resource controls." };
	}

	if (systemdOk) return { mode: "systemd-run" };
	if (niceOk) return { mode: "nice-ionice", warning: "resourceControlMode=auto could not use user systemd-run; using nice/ionice fallback." };
	return { mode: "none", warning: "resource controls are enabled, but no supported helper was detected; spawning without resource controls." };
}

function systemdPlan(input: ResourceControlSpawnInput, settings: ResourceControlSettings, warning?: string): ResourceControlSpawnPlan {
	const unitName = makeSystemdUnitName(input.taskId, input.now ?? Date.now());
	const args = [
		"--user",
		"--quiet",
		"--wait",
		"--pipe",
		"--collect",
		`--unit=${unitName}`,
		`--working-directory=${input.cwd}`,
		...systemdResourcePropertyArgs(settings),
		"--",
		input.shell,
		...input.shellArgs,
		input.command,
	];
	return {
		file: "systemd-run",
		args,
		metadata: {
			mode: "systemd-run",
			requestedMode: settings.mode,
			unitName,
			warning,
		},
		warnings: warning ? [warning] : [],
	};
}

function niceIonicePlan(
	input: ResourceControlSpawnInput,
	settings: ResourceControlSettings,
	probes: ResourceControlProbes | undefined,
	warning?: string,
): ResourceControlSpawnPlan {
	const platform = platformFor(probes);
	const hasCommand = commandProbeFor(probes, platform);
	const useNice = hasCommand("nice");
	const useIonice = hasCommand("ionice");
	let file = input.shell;
	let args = [...input.shellArgs, input.command];
	if (useIonice) {
		file = "ionice";
		args = ["-c", ioniceClassNumber(settings.ioniceClass), ...(settings.ioniceClass === "idle" ? [] : ["-n", String(settings.ioniceLevel)]), input.shell, ...input.shellArgs, input.command];
	}
	if (useNice) {
		args = ["-n", String(settings.nice), file, ...args];
		file = "nice";
	}
	return {
		file,
		args,
		metadata: {
			mode: "nice-ionice",
			requestedMode: settings.mode,
			warning,
		},
		warnings: warning ? [warning] : [],
	};
}

export function planResourceControlledSpawn(input: ResourceControlSpawnInput): ResourceControlSpawnPlan {
	const settings = input.settings ?? readResourceControlSettings(input.cwd);
	const origin = input.origin ?? "bg_task";
	const resolution = resolveMode(settings, origin, input.probes);
	if (resolution.mode === "none") {
		const plan = basePlan(input);
		if (resolution.warning) plan.warnings.push(resolution.warning);
		return plan;
	}
	if (resolution.mode === "systemd-run") return systemdPlan(input, settings, resolution.warning);
	return niceIonicePlan(input, settings, input.probes, resolution.warning);
}

function defaultStopRunner(command: string, args: string[]): { status: number | null; error?: Error; stderr?: string | Buffer | null } {
	try {
		const result = spawnSync(command, args, { encoding: "utf8", timeout: SYSTEMCTL_TIMEOUT_MS });
		return { status: result.status, error: result.error, stderr: result.stderr };
	} catch (error) {
		return { status: null, error: error instanceof Error ? error : new Error(String(error)) };
	}
}

export function stopResourceControlledTask(
	metadata: ResourceControlMetadata | undefined,
	signal: NodeJS.Signals,
	runner: StopRunner = defaultStopRunner,
): ResourceControlStopResult {
	if (metadata?.mode !== "systemd-run" || !metadata.unitName) return { attempted: false, ok: false };
	const args = signal === "SIGKILL"
		? ["--user", "kill", `--signal=${signal}`, metadata.unitName]
		: ["--user", "stop", "--no-block", metadata.unitName];
	const result = runner("systemctl", args);
	const ok = result.status === 0;
	return {
		attempted: true,
		ok,
		command: "systemctl",
		args,
		...(ok ? {} : { error: result.error?.message ?? String(result.stderr ?? "systemctl failed") }),
	};
}

export interface SystemdUnitActiveProbeDeps {
	platform?: () => NodeJS.Platform;
	run?: ProbeRunner;
}

/**
 * Build an asynchronous unit liveness probe: true while the unit is active,
 * false when `systemctl is-active` reports it inactive, null when it cannot
 * be queried.
 *
 * The user manager's reachability is probed once and cached, so a host with
 * no `systemctl` or no user bus pays one probe, not one per task per pass.
 * A probe that timed out or was signalled settles nothing and is retried by
 * the next caller.
 */
export function createSystemdUnitActiveProbe(deps: SystemdUnitActiveProbeDeps = {}): (unitName: string) => Promise<boolean | null> {
	const platform = deps.platform ?? (() => process.platform);
	const run = deps.run ?? runProbe;
	let userManager: Promise<boolean | null> | null = null;
	const userManagerReachable = async (): Promise<boolean> => {
		userManager ??= run("systemctl", SYSTEMD_USER_MANAGER_PROBE_ARGS).then((result) => {
			switch (result.kind) {
				case "exited": return result.status === 0;
				case "spawn-failed": return false;
				case "timed-out":
				case "signalled": return null;
				default: {
					const unreachable: never = result;
					throw new Error(`unknown probe result: ${JSON.stringify(unreachable)}`);
				}
			}
		});
		const reachable = await userManager;
		if (reachable === null) userManager = null;
		return reachable === true;
	};
	return async (unitName: string): Promise<boolean | null> => {
		if (!unitName || platform() !== "linux") return null;
		if (!(await userManagerReachable())) return null;
		const result = await run("systemctl", ["--user", "is-active", "--quiet", unitName]);
		if (result.kind !== "exited") return null;
		if (result.status === 0) return true;
		if (result.status === 3) return false;
		return null;
	};
}

export const defaultSystemdUnitActive = createSystemdUnitActiveProbe();
