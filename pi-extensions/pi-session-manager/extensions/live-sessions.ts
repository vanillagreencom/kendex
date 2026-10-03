import { randomUUID } from "node:crypto";
import { mkdir, readdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { piUserDir } from "./package-config.js";
import { canonicalPath } from "./paths.js";

/** A running Pi session's claim on its session file and session id. Each
 * extension runtime writes one record, so two runtimes in one process never
 * overwrite each other's claim. */
export interface SessionOwner {
	pid: number;
	cwd: string;
	sessionFile: string;
	sessionId: string;
}

type ClaimContext = Pick<ExtensionContext, "cwd"> & {
	sessionManager: Pick<ExtensionContext["sessionManager"], "getSessionFile" | "getSessionId">;
};

/** Shared by every Pi process of this user directory, which is how one lane
 * sees another lane's live sessions. */
function liveDir(): string {
	return join(piUserDir(), "kendex", "pi-session-manager", "live");
}

function errorCode(error: unknown): string | undefined {
	return (error as NodeJS.ErrnoException).code;
}

// EPERM is a live process this user may not signal. A reused pid reads as
// live too, which keeps a session that could have been deleted: the safe side.
function processAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		if (errorCode(error) === "ESRCH") return false;
		if (errorCode(error) === "EPERM") return true;
		throw error;
	}
}

function parseOwner(text: string, path: string): SessionOwner {
	let value: Partial<SessionOwner>;
	try {
		value = JSON.parse(text) as Partial<SessionOwner>;
	} catch (error) {
		throw new Error(`unreadable live-session record ${path}: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (typeof value.pid !== "number" || typeof value.cwd !== "string" || typeof value.sessionFile !== "string" || typeof value.sessionId !== "string") {
		throw new Error(`unreadable live-session record ${path}: expected pid, cwd, sessionFile and sessionId`);
	}
	return { pid: value.pid, cwd: value.cwd, sessionFile: value.sessionFile, sessionId: value.sessionId };
}

/** The running Pi that owns the session file or its id, if any. A session id
 * alone is enough: the per-session kendex tree a delete removes is keyed by
 * it. A record whose process has ended is removed here. */
export async function liveOwner(sessionPath: string, sessionId: string): Promise<SessionOwner | undefined> {
	const dir = liveDir();
	let names: string[];
	try {
		names = await readdir(dir);
	} catch (error) {
		if (errorCode(error) === "ENOENT") return undefined;
		throw error;
	}
	const target = canonicalPath(sessionPath);
	for (const name of names) {
		// A `.json.tmp` is a claim still being written; its rename is the claim.
		if (!name.endsWith(".json")) continue;
		const path = join(dir, name);
		let text: string;
		try {
			text = await readFile(path, "utf8");
		} catch (error) {
			// Released between the listing and the read.
			if (errorCode(error) === "ENOENT") continue;
			throw error;
		}
		const owner = parseOwner(text, path);
		if (!processAlive(owner.pid)) {
			await rm(path, { force: true });
			continue;
		}
		if (owner.sessionId === sessionId || canonicalPath(owner.sessionFile) === target) return owner;
	}
	return undefined;
}

async function writeClaim(path: string, owner: SessionOwner): Promise<void> {
	await mkdir(liveDir(), { recursive: true, mode: 0o700 });
	const temp = `${path}.tmp`;
	await writeFile(temp, `${JSON.stringify(owner)}\n`, { mode: 0o600 });
	await rename(temp, path);
}

// `/reload` shuts a runtime down and builds its replacement on the same
// session; the record paths a reload keeps wait here for the next runtime this
// process installs, so the session stays claimed across the gap.
const RELOAD_HANDOVER_SYMBOL = Symbol.for("kendex.pi-session-manager.reload-claims");

function reloadHandover(): string[] {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const slot = host[RELOAD_HANDOVER_SYMBOL];
	if (Array.isArray(slot)) return slot as string[];
	const fresh: string[] = [];
	host[RELOAD_HANDOVER_SYMBOL] = fresh;
	return fresh;
}

/** Claims the session each `session_start` opens and releases it at
 * `session_shutdown`. A session with no file (`--no-session`) is not claimed.
 * A reload keeps the record and the replacement runtime rewrites it. */
export function installSessionClaim(pi: Pick<ExtensionAPI, "on">): void {
	const path = reloadHandover().shift() ?? join(liveDir(), `${process.pid}-${randomUUID()}.json`);
	const release = () => rm(path, { force: true });
	pi.on("session_start", async (_event, ctx: ClaimContext) => {
		const sessionFile = ctx.sessionManager.getSessionFile();
		if (!sessionFile) {
			await release();
			return;
		}
		await writeClaim(path, { pid: process.pid, cwd: ctx.cwd, sessionFile, sessionId: ctx.sessionManager.getSessionId() });
	});
	pi.on("session_shutdown", async (event) => {
		switch (event.reason) {
			case "reload":
				reloadHandover().push(path);
				return;
			case "quit":
			case "new":
			case "resume":
			case "fork":
				await release();
				return;
			default: {
				const unknownReason: never = event.reason;
				throw new Error(`unknown session_shutdown reason ${String(unknownReason)}`);
			}
		}
	});
}
