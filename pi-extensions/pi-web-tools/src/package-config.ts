/**
 * The settings reader every pi-extensions package vendors. Each package carries
 * this file byte-identical, and `pi-extensions/package-policy.test.mjs` holds
 * the copies equal: change one, then copy it over every other
 * `package-config.ts` in the tree.
 *
 * It owns the project-trust registry, the settings-file order and the
 * `kendex.extensionManager.config` walk, and it memoizes all of them. Widgets
 * and renderers read settings many times per frame; going to the disk on each
 * read kept every lane's render loop busy. A memoized answer is served for
 * `SETTINGS_RECHECK_MS` with no filesystem work, and
 * `installSettingsCacheRefresh` drops every answer when the extension manager
 * announces a settings change and when a session starts.
 */
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

/** What pi-extension-manager emits on `pi.events` after it writes a setting. */
export const SETTINGS_CHANGED_EVENT = "kendex:extension-settings-changed";

/** How long a memoized answer is served before its inputs are read again. */
export const SETTINGS_RECHECK_MS = 1000;

export function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

/** Root-anchored as `crates/core/src/harness/pi.rs::pi_root_is_absolute_for`
 * means it, which `isAbsolute` is not: it calls a driveless `\root` absolute
 * where the renderer does not, putting the two on different roots. */
function rootAnchored(path: string, windows: boolean): boolean {
	return windows ? /^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+)/.test(path) : path.startsWith("/");
}

export function piUserDir(): string {
	const override = expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "");
	return resolve(rootAnchored(override, process.platform === "win32") ? override : expandHome("~/.pi/agent"));
}

interface MemoEntry {
	/** `performance.now()`, a monotonic clock, so a backward wall-clock step
	 * cannot hold an entry past its window. */
	readAt: number;
	fingerprint: string | undefined;
	value: unknown;
}

const memo = new Map<string, MemoEntry>();

/** Drops every memoized answer so the next read goes back to disk. */
export function clearPackageConfigCache(): void {
	memo.clear();
}

/**
 * `compute()` for `key`, served from memory for `SETTINGS_RECHECK_MS`. Once the
 * window closes, `fingerprint` (when given) runs first, and a fingerprint equal
 * to the one the value was computed under keeps the value, and its identity,
 * for another window without calling `compute`. Without a fingerprint the
 * value is computed again. `clearPackageConfigCache` drops every entry.
 */
export function settingsMemo<T>(key: string, compute: () => T, fingerprint?: () => string): T {
	const now = performance.now();
	const entry = memo.get(key);
	if (entry && now - entry.readAt < SETTINGS_RECHECK_MS) return entry.value as T;
	const print = fingerprint?.();
	if (entry && print !== undefined && entry.fingerprint === print) {
		entry.readAt = now;
		return entry.value as T;
	}
	const value = compute();
	memo.set(key, { readAt: now, fingerprint: print, value });
	return value;
}

/** The project settings file for `cwd`: the nearest ancestor's
 * `.pi/settings.json`, stopping at a `.pi`, `.git` or `.kendex-lock.json`. */
export function projectSettingsPath(cwd: string): string {
	let current = resolve(cwd);
	while (true) {
		const candidate = join(current, ".pi", "settings.json");
		if (existsSync(candidate)) return candidate;
		if (existsSync(join(current, ".pi")) || existsSync(join(current, ".git")) || existsSync(join(current, ".kendex-lock.json"))) return candidate;
		const parent = dirname(current);
		if (parent === current) return join(resolve(cwd), ".pi", "settings.json");
		current = parent;
	}
}

const PROJECT_TRUST_SYMBOL = Symbol.for("kendex.pi.project-trust");

interface ProjectTrustRegistry {
	projectSettings?: Map<string, boolean>;
}

/** Shared by every package in the process: whichever package records Pi's
 * trust answer first, every package reads it. */
function projectTrustRegistry(): ProjectTrustRegistry {
	const host = globalThis as unknown as Record<PropertyKey, ProjectTrustRegistry | undefined>;
	const existing = host[PROJECT_TRUST_SYMBOL];
	if (existing) return existing;
	const created: ProjectTrustRegistry = {};
	host[PROJECT_TRUST_SYMBOL] = created;
	return created;
}

/**
 * Pi's answer to "has this person trusted this workspace". Only a plain `true`
 * counts: a Pi with no such method, or one that throws, is not trusted. The
 * answer gates reading a project's settings and running a project's own
 * scripts, both safe to withhold and unsafe to grant by accident.
 */
export function projectTrusted(ctx: { isProjectTrusted?: () => boolean }): boolean {
	try {
		return ctx.isProjectTrusted?.() === true;
	} catch {
		return false;
	}
}

/** Records Pi's trust answer against the settings file `settingsPath`. */
export function recordSettingsTrust(settingsPath: string, ctx: { isProjectTrusted?: () => boolean }): void {
	const registry = projectTrustRegistry();
	if (!registry.projectSettings) registry.projectSettings = new Map();
	registry.projectSettings.set(settingsPath, projectTrusted(ctx));
}

export function recordProjectTrust(ctx: { cwd?: string; isProjectTrusted?: () => boolean }): void {
	if (!ctx.cwd) return;
	recordSettingsTrust(projectSettingsPath(ctx.cwd), ctx);
}

/** Read on every call, never memoized: a trust answer recorded by any package
 * takes effect on the next read. */
export function settingsFileTrusted(settingsPath: string): boolean {
	return projectTrustRegistry().projectSettings?.get(settingsPath) === true;
}

function memoizedProjectSettingsPath(cwd: string): string {
	return settingsMemo(`project-settings-path\0${cwd}`, () => projectSettingsPath(cwd));
}

/** The project settings file for `cwd` when Pi trusts the project, else
 * `undefined`. */
export function trustedProjectSettingsPath(cwd = process.cwd()): string | undefined {
	const project = memoizedProjectSettingsPath(cwd);
	return settingsFileTrusted(project) ? project : undefined;
}

export function projectSettingsTrustedForCwd(cwd = process.cwd()): boolean {
	return trustedProjectSettingsPath(cwd) !== undefined;
}

/** The user settings file, then the project's when Pi trusts the project. */
export function piSettingsPaths(cwd = process.cwd()): string[] {
	const user = join(piUserDir(), "settings.json");
	const project = trustedProjectSettingsPath(cwd);
	return project === undefined ? [user] : [user, project];
}

export type SettingsRecord = Record<string, unknown>;

/** One settings file that exists. A file that does not parse, or that cannot be
 * read for any reason but its absence, is `malformed`; a document that parses
 * to something other than an object reads as an empty one. */
export type SettingsFile =
	| { kind: "parsed"; path: string; settings: Readonly<SettingsRecord> }
	| { kind: "malformed"; path: string; error: string };

function isRecord(value: unknown): value is SettingsRecord {
	return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

/** Memoized values are shared by every caller, so a caller that wrote into one
 * would change what the next caller reads. Frozen, that write throws instead. */
function deepFreeze<T>(value: T): T {
	if (value && typeof value === "object" && !Object.isFrozen(value)) {
		Object.freeze(value);
		for (const child of Object.values(value)) deepFreeze(child);
	}
	return value;
}

type FileText = { kind: "absent" } | { kind: "text"; text: string } | { kind: "unreadable"; error: string };

function readText(path: string): FileText {
	try {
		return { kind: "text", text: readFileSync(path, "utf8") };
	} catch (error) {
		const code = (error as { code?: unknown } | null)?.code;
		if (code === "ENOENT" || code === "ENOTDIR") return { kind: "absent" };
		return { kind: "unreadable", error: error instanceof Error ? error.message : String(error) };
	}
}

/**
 * The files at `paths` that exist, in order. Each window re-reads their text;
 * text equal to what the last parse saw keeps the last answer, so an unchanged
 * file is parsed once and its callers keep one identity for it.
 */
export function readSettingsFiles(paths: readonly string[]): readonly SettingsFile[] {
	let texts: FileText[] = [];
	return settingsMemo(
		`settings-files\0${paths.join("\0")}`,
		() =>
			deepFreeze(
				paths.flatMap((path, index): SettingsFile[] => {
					const text = texts[index] ?? readText(path);
					if (text.kind === "absent") return [];
					if (text.kind === "unreadable") return [{ kind: "malformed", path, error: text.error }];
					try {
						const parsed: unknown = JSON.parse(text.text);
						return [{ kind: "parsed", path, settings: isRecord(parsed) ? parsed : {} }];
					} catch (error) {
						return [{ kind: "malformed", path, error: error instanceof Error ? error.message : String(error) }];
					}
				}),
			),
		() => {
			texts = paths.map(readText);
			return JSON.stringify(texts);
		},
	);
}

/** `packageId`'s object under `kendex.extensionManager.config` in one parsed
 * settings document, or `undefined` where it holds none. */
export function packageConfigIn(settings: Readonly<SettingsRecord>, packageId: string): Readonly<SettingsRecord> | undefined {
	const kendex = settings.kendex;
	const manager = isRecord(kendex) ? kendex.extensionManager : undefined;
	const config = isRecord(manager) ? manager.config : undefined;
	const own = isRecord(config) ? config[packageId] : undefined;
	return isRecord(own) ? own : undefined;
}

/** Merged configs per package id, keyed by the file list they were merged
 * from: `readSettingsFiles` hands back a new list whenever a file changed. */
const configsByFiles = new WeakMap<readonly SettingsFile[], Map<string, Readonly<SettingsRecord>>>();

/** `packageId`'s config over the files at `paths`, later files overriding
 * earlier ones key by key. A malformed file contributes nothing. */
export function readPackageConfigAt(packageId: string, paths: readonly string[]): Readonly<SettingsRecord> {
	const files = readSettingsFiles(paths);
	let configs = configsByFiles.get(files);
	if (!configs) {
		configs = new Map();
		configsByFiles.set(files, configs);
	}
	const known = configs.get(packageId);
	if (known) return known;
	const merged: SettingsRecord = {};
	for (const file of files) {
		if (file.kind !== "parsed") continue;
		const config = packageConfigIn(file.settings, packageId);
		if (config) Object.assign(merged, config);
	}
	const frozen = Object.freeze(merged);
	configs.set(packageId, frozen);
	return frozen;
}

/** `packageId`'s config over `piSettingsPaths(cwd)`. */
export function readPackageConfig(packageId: string, cwd = process.cwd()): Readonly<SettingsRecord> {
	return readPackageConfigAt(packageId, piSettingsPaths(cwd));
}

/** The part of Pi's `ExtensionAPI` the refresh needs. */
export interface SettingsRefreshHost {
	on(event: "session_start", handler: () => void): unknown;
	on(event: "session_shutdown", handler: () => void): unknown;
	events: { on(channel: string, handler: (data: unknown) => void): () => void };
}

/**
 * Drops every memoized answer when a session starts, which is where the cwd
 * and the project's trust can change, and whenever pi-extension-manager
 * announces a settings change. The subscription lives from `session_start` to
 * `session_shutdown`, as Pi asks of any listener.
 */
export function installSettingsCacheRefresh(pi: SettingsRefreshHost): void {
	let unsubscribe: (() => void) | undefined;
	pi.on("session_start", () => {
		clearPackageConfigCache();
		unsubscribe ??= pi.events.on(SETTINGS_CHANGED_EVENT, () => clearPackageConfigCache());
	});
	pi.on("session_shutdown", () => {
		unsubscribe?.();
		unsubscribe = undefined;
		clearPackageConfigCache();
	});
}
