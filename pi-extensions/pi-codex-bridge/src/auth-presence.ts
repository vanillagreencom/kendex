import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const LOGIN_MISSING_KEY = "codex-login-missing";

/** Resolve the one Codex home whose CLI login this bridge may use:
 * `PI_CODEX_BRIDGE_HOME`, else `CODEX_HOME`, else `~/.codex`. The bridge's own
 * variable lets a fleet give the bridge a home apart from the one a `codex` in
 * Pi's tool shell reads. A blank value counts as unset, as Codex itself treats
 * a blank `CODEX_HOME`. */
export function resolveCodexHome(env: NodeJS.ProcessEnv = process.env, userHome = homedir()): string {
	return env.PI_CODEX_BRIDGE_HOME?.trim() || codexCliHome(env, userHome);
}

/** The home a plain `codex` run signs in to: `CODEX_HOME`, else `~/.codex`. */
function codexCliHome(env: NodeJS.ProcessEnv, userHome: string): string {
	return env.CODEX_HOME?.trim() || join(userHome, ".codex");
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
	if (!hasCodexLogin(codexHome)) throw new Error(loginMissingMessage(codexHome));
}

/** The missing-login diagnostic: the keyed first line, then how to sign in to
 * the bridge home. Where a plain `codex login` signs in to that home, the
 * remedy is that command, which also creates `~/.codex`. Otherwise the steps
 * are in words, because the Codex CLI reads only `CODEX_HOME` and refuses a
 * `CODEX_HOME` folder that does not exist (measured on 0.163.0 and 0.166.0),
 * and setting a variable for one command is shell-specific. */
export function loginMissingMessage(codexHome: string, env: NodeJS.ProcessEnv = process.env, userHome = homedir()): string {
	const remedy = codexHome === codexCliHome(env, userHome)
		? "Sign in: codex login"
		: `PI_CODEX_BRIDGE_HOME gives Pi Codex its own Codex home, ${codexHome}. Make that folder if it does not exist. Then set the CODEX_HOME environment variable to that folder and run codex login.`;
	return `${LOGIN_MISSING_KEY} home=${codexHome}\nPi Codex needs a Codex CLI login. ${remedy}`;
}
