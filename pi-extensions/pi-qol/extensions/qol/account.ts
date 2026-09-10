// The subscription account a Claude-bridge session bills to.
//
// SECURITY: this module reads `.claude.json`, which holds profile metadata, and
// takes one field from it. It never opens `.credentials.json` and never logs a
// path or a value.

import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Provider id the Claude bridge registers its subscription models under.
 *  Spelled here rather than imported: pi-qol does not depend on
 *  `@vanillagreen/pi-claude-bridge`, which a session need not have installed. */
export const CLAUDE_BRIDGE_PROVIDER = "pi-claude";

/** The Claude config directory this process routes to, resolved as Claude Code
 *  itself resolves it. A set-but-blank `CLAUDE_CONFIG_DIR` is treated as unset,
 *  because an empty string would otherwise resolve the account file against the
 *  filesystem root. */
export function claudeConfigDir(env: NodeJS.ProcessEnv = process.env): string {
	const configured = env.CLAUDE_CONFIG_DIR;
	if (typeof configured === "string" && configured.trim().length > 0) return configured.trim();
	return join(homedir(), ".claude");
}

interface AccountRead {
	path: string;
	mtimeMs: number;
	size: number;
	email: string | undefined;
}

let lastRead: AccountRead | undefined;

/** Test seam: the statusline is rendered per keystroke and the account file
 *  runs to tens of kilobytes, so a parse is reused until the file changes. */
export function resetAccountCache(): void {
	lastRead = undefined;
}

/** The email of the account signed in to {@link claudeConfigDir}, or undefined
 *  when the file is absent, unreadable, malformed, or carries no signed-in
 *  account. Each of those is "not known", and the caller renders no account
 *  rather than a guess: an email in this footer names which subscription the
 *  turn is billed to, so a wrong one is worse than none. */
export function claudeAccountEmail(env: NodeJS.ProcessEnv = process.env): string | undefined {
	const path = join(claudeConfigDir(env), ".claude.json");
	let mtimeMs: number;
	let size: number;
	try {
		const stats = statSync(path);
		mtimeMs = stats.mtimeMs;
		size = stats.size;
	} catch {
		lastRead = undefined;
		return undefined;
	}
	if (lastRead && lastRead.path === path && lastRead.mtimeMs === mtimeMs && lastRead.size === size) return lastRead.email;
	let email: string | undefined;
	try {
		const parsed = JSON.parse(readFileSync(path, "utf8")) as { oauthAccount?: { emailAddress?: unknown } };
		const value = parsed?.oauthAccount?.emailAddress;
		email = typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
	} catch {
		email = undefined;
	}
	lastRead = { email, mtimeMs, path, size };
	return email;
}
