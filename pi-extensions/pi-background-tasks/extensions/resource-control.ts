import { spawnSync } from "node:child_process";

import { runProbe, runProbeSync, type ProbeResult, type ProbeRunner } from "./probes.js";
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
	commandLookup?: CommandLookup;
	userSystemdAvailable?: () => boolean;
	userManager?: UserManagerReachability;
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

/**
 * Whether the user's systemd manager answers. Spawn planning asks
 * synchronously and liveness probes asynchronously; both read one memo, so
 * once either settles the answer the other never probes.
 */
export interface UserManagerReachability {
	/** null: this call's probe settled nothing. */
	sync(): boolean | null;
	/** Concurrent callers share one probe. */
	check(): Promise<boolean>;
}

export interface UserManagerReachabilityDeps {
	run?: ProbeRunner;
	runSync?: (file: string, args: string[]) => ProbeResult;
}

function settledSuccess(result: ProbeResult): boolean | null {
	return result.kind === "unsettled" ? null : result.kind === "exited" && result.status === 0;
}

export function createUserManagerReachability(deps: UserManagerReachabilityDeps = {}): UserManagerReachability {
	const run = deps.run ?? runProbe;
	const runSync = deps.runSync ?? runProbeSync;
	let answer: boolean | null = null;
	let inFlight: Promise<boolean> | null = null;
	return {
		sync() {
			answer ??= settledSuccess(runSync("systemctl", SYSTEMD_USER_MANAGER_PROBE_ARGS));
			return answer;
		},
		check() {
			if (answer !== null) return Promise.resolve(answer);
			inFlight ??= run("systemctl", SYSTEMD_USER_MANAGER_PROBE_ARGS).then((result) => {
				answer ??= settledSuccess(result);
				inFlight = null;
				return answer === true;
			});
			return inFlight;
		},
	};
}

/**
 * The user manager answer this extension load reads. Pi re-imports the
 * extension on /reload, which starts a fresh memo.
 */
const userManager = createUserManagerReachability();

function finiteInt(value: number, fallback: number): number {
	return Number.isFinite(value) ? Math.round(value) : fallback;
}

function clampInt(value: number, min: number, max: number, fallback: number): number {
	return Math.min(max, Math.max(min, finiteInt(value, fallback)));
}

export function readResourceControlSettings(cwd?: string): ResourceControlSettings {
	return {
		enabled: settingBoolean("resourceControlEnabled", true, cwd),
		mode: settingEnum("resourceControlMode", RESOURCE_CONTROL_MODES, "nice-ionice", cwd),
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

/** Whether a helper command is on PATH, memoized per platform and command. */
export interface CommandLookup {
	exists(command: string, platform: NodeJS.Platform): boolean;
}

export interface CommandLookupDeps {
	runSync?: (file: string, args: string[]) => ProbeResult;
}

export function createCommandLookup(deps: CommandLookupDeps = {}): CommandLookup {
	const runSync = deps.runSync ?? runProbeSync;
	const settled = new Map<string, boolean>();
	return {
		exists(command, platform) {
			const key = `${platform}:${command}`;
			const known = settled.get(key);
			if (known !== undefined) return known;
			const answer = settledSuccess(platform === "win32"
				? runSync("where", [command])
				: runSync("sh", ["-c", "command -v \"$1\" >/dev/null 2>&1", "sh", command]));
			// A timed-out or killed lookup reads as absent for this spawn only;
			// the next spawn asks again.
			if (answer === null) return false;
			settled.set(key, answer);
			return answer;
		},
	};
}

/**
 * The helper lookups this extension load reads. Whether a helper is on PATH
 * does not change while Pi runs; Pi re-imports the extension on /reload,
 * which starts a fresh memo.
 */
const commandLookup = createCommandLookup();

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

function userSystemdAvailable(commandProbe: (command: string) => boolean, platform: NodeJS.Platform, settings: ResourceControlSettings, manager: UserManagerReachability): boolean {
	if (platform !== "linux") return false;
	if (!commandProbe("systemd-run") || !commandProbe("systemctl")) return false;
	const cacheKey = systemdProbeCacheKey(settings);
	const cached = cachedUserSystemdRunnable.get(cacheKey);
	if (cached !== undefined) return cached;
	// A manager that did not answer is cached as unavailable for this settings
	// key, so spawn planning blocks Pi's thread on it once; the asynchronous
	// liveness check keeps asking.
	if (manager.sync() !== true) {
		cachedUserSystemdRunnable.set(cacheKey, false);
		return false;
	}
	try {
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
	const lookup = probes?.commandLookup ?? commandLookup;
	return probes?.commandExists ?? ((command: string) => lookup.exists(command, platform));
}

function systemdProbeFor(probes: ResourceControlProbes | undefined, commandProbe: (command: string) => boolean, platform: NodeJS.Platform, settings: ResourceControlSettings): () => boolean {
	return probes?.userSystemdAvailable ?? (() => userSystemdAvailable(commandProbe, platform, settings, probes?.userManager ?? userManager));
}

function originApplies(settings: ResourceControlSettings, origin: ResourceControlOrigin): boolean {
	return origin === "auto-background" ? settings.applyToAutoBackground : settings.applyToBgTask;
}

interface NiceIoniceHelpers {
	nice: boolean;
	ionice: boolean;
}

/** The helpers a nice-ionice plan wraps the shell in; null when it has none. */
function niceIoniceHelpers(commandProbe: (command: string) => boolean, platform: NodeJS.Platform): NiceIoniceHelpers | null {
	if (platform === "win32") return null;
	const helpers = { nice: commandProbe("nice"), ionice: commandProbe("ionice") };
	return helpers.nice || helpers.ionice ? helpers : null;
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

type ModeResolution =
	| { mode: "none"; warning?: string }
	| { mode: "systemd-run"; warning?: string }
	| { mode: "nice-ionice"; helpers: NiceIoniceHelpers; warning?: string };

function resolveMode(
	settings: ResourceControlSettings,
	origin: ResourceControlOrigin,
	probes: ResourceControlProbes | undefined,
): ModeResolution {
	if (!settings.enabled || settings.mode === "off" || !originApplies(settings, origin)) return { mode: "none" };

	const platform = platformFor(probes);
	const hasCommand = commandProbeFor(probes, platform);
	// The systemd probe can block Pi's thread on a transient unit, so only the
	// modes that may pick systemd-run ask it.
	const hasSystemd = systemdProbeFor(probes, hasCommand, platform, settings);

	if (settings.mode === "systemd-run") {
		return hasSystemd()
			? { mode: "systemd-run" }
			: { mode: "none", warning: "resourceControlMode=systemd-run requested, but usable user systemd-run support was not detected; spawning without resource controls." };
	}

	if (settings.mode === "nice-ionice") {
		const helpers = niceIoniceHelpers(hasCommand, platform);
		return helpers
			? { mode: "nice-ionice", helpers }
			: { mode: "none", warning: "resourceControlMode=nice-ionice requested, but nice/ionice helpers were not detected; spawning without resource controls." };
	}

	if (hasSystemd()) return { mode: "systemd-run" };
	const helpers = niceIoniceHelpers(hasCommand, platform);
	if (helpers) return { mode: "nice-ionice", helpers, warning: "resourceControlMode=auto could not use user systemd-run; using nice/ionice fallback." };
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
	helpers: NiceIoniceHelpers,
	warning?: string,
): ResourceControlSpawnPlan {
	let file = input.shell;
	let args = [...input.shellArgs, input.command];
	if (helpers.ionice) {
		file = "ionice";
		args = ["-c", ioniceClassNumber(settings.ioniceClass), ...(settings.ioniceClass === "idle" ? [] : ["-n", String(settings.ioniceLevel)]), input.shell, ...input.shellArgs, input.command];
	}
	if (helpers.nice) {
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
	switch (resolution.mode) {
		case "none": {
			const plan = basePlan(input);
			if (resolution.warning) plan.warnings.push(resolution.warning);
			return plan;
		}
		case "systemd-run":
			return systemdPlan(input, settings, resolution.warning);
		case "nice-ionice":
			return niceIonicePlan(input, settings, resolution.helpers, resolution.warning);
		default: {
			const unreachable: never = resolution;
			throw new Error(`resource control resolved an unknown mode: ${JSON.stringify(unreachable)}`);
		}
	}
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
	userManager?: UserManagerReachability;
}

/**
 * Build an asynchronous unit liveness probe: true while the unit is active,
 * false when `systemctl is-active` reports it inactive, null when it cannot
 * be queried. An unreachable user manager answers null without a unit query.
 */
export function createSystemdUnitActiveProbe(deps: SystemdUnitActiveProbeDeps = {}): (unitName: string) => Promise<boolean | null> {
	const platform = deps.platform ?? (() => process.platform);
	const run = deps.run ?? runProbe;
	const manager = deps.userManager ?? userManager;
	return async (unitName: string): Promise<boolean | null> => {
		if (!unitName || platform() !== "linux") return null;
		if (!(await manager.check())) return null;
		const result = await run("systemctl", ["--user", "is-active", "--quiet", unitName]);
		if (result.kind !== "exited") return null;
		if (result.status === 0) return true;
		if (result.status === 3) return false;
		return null;
	};
}

export const defaultSystemdUnitActive = createSystemdUnitActiveProbe();
