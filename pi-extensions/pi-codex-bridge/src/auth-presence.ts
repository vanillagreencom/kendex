import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const LOGIN_MISSING_KEY = "codex-login-missing";

/** Resolve the one Codex home whose CLI login this bridge may use:
 * `PI_CODEX_BRIDGE_HOME`, else `CODEX_HOME`, else `~/.codex`. The bridge's own
 * variable lets a fleet give the bridge a home apart from the one a `codex` in
 * Pi's tool shell reads. A blank value counts as unset, as Codex itself treats
 * a blank `CODEX_HOME`. */
export function resolveCodexHome(env: NodeJS.ProcessEnv = process.env, userHome = homedir()): string {
	const configured = env.PI_CODEX_BRIDGE_HOME?.trim() || env.CODEX_HOME?.trim();
	return configured ? configured : join(userHome, ".codex");
}

/**
 * Whether the login file exists. The file is never opened: Codex owns its
 * contents and its refresh. A keyring login (`cli_auth_credentials_store =
 * "keyring"`) keeps no such file, so it reads as absent.
 */
export function hasCodexLogin(codexHome: string): boolean {
	return existsSync(join(codexHome, "auth.json"));
}

export function requireCodexLogin(codexHome: string): void {
	if (!hasCodexLogin(codexHome)) {
		throw new Error(`${LOGIN_MISSING_KEY} home=${codexHome}\nSign in with the Codex CLI first: codex login`);
	}
}
