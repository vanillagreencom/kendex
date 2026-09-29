import { existsSync, mkdirSync } from "node:fs";
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

function taskDir(): string {
	const configured = settingString("taskDir", "");
	return process.env.PI_BG_TASK_DIR?.trim() || (configured ? resolve(expandHome(configured)) : join(tmpdir(), "kendex-pi-bg"));
}

function safeLabel(input: string): string {
	return input.replaceAll(/[^a-z0-9-]+/gi, "-").replaceAll(/^-+|-+$/g, "").slice(0, 48) || "task";
}

export function logFilePath(id: string, now: number = Date.now()): string {
	const dir = taskDir();
	mkdirSync(dir, { recursive: true, mode: 0o700 });
	return join(dir, `${safeLabel(id)}-${now}.log`);
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
