import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join, resolve } from "node:path";

import { CONFIG_ID } from "./constants.js";
import { expandHome, piUserDir, readPackageConfig } from "./package-config.js";
import type { kendexConfig } from "./types.js";

export function readkendexConfig(cwd?: string): kendexConfig {
	return readPackageConfig(CONFIG_ID, cwd) as kendexConfig;
}

export function settingNumber(key: string, fallback: number, cwd?: string): number {
	const value = readkendexConfig(cwd)[key];
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
	return Number.isFinite(parsed) ? parsed : fallback;
}

export function settingBoolean(key: string, fallback: boolean, cwd?: string): boolean {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "boolean" ? value : fallback;
}

export function settingString(key: string, fallback: string, cwd?: string): string {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

export function settingEnum<T extends string>(key: string, allowed: readonly T[], fallback: T, cwd?: string): T {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "string" && (allowed as readonly string[]).includes(value) ? (value as T) : fallback;
}

export function taskDir(): string {
	const configured = settingString("taskDir", "");
	return process.env.PI_BG_TASK_DIR?.trim() || (configured ? resolve(expandHome(configured)) : join(tmpdir(), "kendex-pi-bg"));
}

function safeLabel(input: string): string {
	return input.replaceAll(/[^a-z0-9-]+/gi, "-").replaceAll(/^-+|-+$/g, "").slice(0, 48) || "task";
}

/** The log file for task `id`, in the lane directory `laneDir`. */
export function logFilePath(laneDir: string, id: string, now: number = Date.now()): string {
	return join(laneDir, `${safeLabel(id)}-${now}.log`);
}

/** The folder, inside the task directory, that holds this package's lane
 *  directories. The task directory is a user setting that may hold other
 *  tools' folders; the retention prune reads only this one. */
export function taskLanesRoot(): string {
	return join(taskDir(), "lanes");
}

/** The directory one session's task logs live in, under taskLanesRoot. */
export function taskLaneDir(sessionId: string): string {
	return join(taskLanesRoot(), sessionId.replace(/[^\w.-]+/g, "_"));
}

export function taskEnv(): NodeJS.ProcessEnv {
	const env = { ...process.env };
	const binDir = join(piUserDir(), "bin");
	if (existsSync(binDir)) {
		const current = env.PATH || "";
		const parts = current.split(delimiter).filter(Boolean);
		if (!parts.includes(binDir)) env.PATH = [binDir, ...parts].join(delimiter);
	}
	return env;
}
