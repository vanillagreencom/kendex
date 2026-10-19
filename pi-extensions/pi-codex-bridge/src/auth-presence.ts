import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const LOGIN_MISSING_KEY = "codex-login-missing";

/** Resolve the one Codex home whose CLI login this bridge may use. */
export function resolveCodexHome(env: NodeJS.ProcessEnv = process.env, userHome = homedir()): string {
	const configured = env.CODEX_HOME;
	if (typeof configured === "string" && configured.trim().length > 0) return configured;
	return join(userHome, ".codex");
}

/** Check only for the login file. Credential contents remain owned by Codex. */
export function hasCodexLogin(codexHome: string): boolean {
	return existsSync(join(codexHome, "auth.json"));
}

export function loginMissingMessage(codexHome: string): string {
	return `${LOGIN_MISSING_KEY} home=${codexHome}`;
}

export function requireCodexLogin(codexHome: string): void {
	if (!hasCodexLogin(codexHome)) throw new Error(loginMissingMessage(codexHome));
}
