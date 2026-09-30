import { randomUUID } from "node:crypto";
import { link, readFile, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { type CommandResult, runCommandAsync } from "./process.js";

export type CargoResult = CommandResult;

/**
 * Run cargo off Pi's thread. Pi's own `pi.exec` is the interface an extension
 * is offered for this, and it cannot serve here: it sends SIGTERM to cargo
 * alone, so the rustc and clippy-driver processes cargo forked keep compiling
 * after a timeout or an abort, and its SIGKILL escalation reads `proc.killed`,
 * which the SIGTERM already set, so it never fires. `runCommandAsync` starts
 * cargo as the leader of its own process group and signals the group.
 */
export function runCargo(args: string[], cwd: string, timeoutMs: number, signal?: AbortSignal): Promise<CargoResult> {
	return runCommandAsync("cargo", args, cwd, timeoutMs, { signal });
}

/**
 * In-process cache for `cargo metadata --workspace_root`. `cargo metadata` is
 * ~0.5-1s even on a warm cache; calling it on every edit/turn adds up. A root
 * a cwd once had it keeps for the session, so caching a hit is sound.
 *
 * Only hits are cached. A failed lookup is a condition the session can leave —
 * cargo arrives on PATH, a manifest is written — and caching it would answer
 * every later turn with a staleness nothing could clear.
 */
const workspaceRootCache = new Map<string, string>();

export async function findCargoWorkspaceRoot(cwd: string, timeoutMs: number, signal?: AbortSignal): Promise<string | null> {
	const cached = workspaceRootCache.get(cwd);
	if (cached !== undefined) return cached;
	const r = await runCargo(["metadata", "--format-version", "1", "--no-deps"], cwd, timeoutMs, signal);
	if (r.stoppedBy !== null || r.exitCode !== 0) return null;
	let root: string | null = null;
	try {
		const meta = JSON.parse(r.stdout);
		if (typeof meta?.workspace_root === "string" && meta.workspace_root) root = meta.workspace_root;
	} catch {
		root = null;
	}
	if (root) workspaceRootCache.set(cwd, root);
	return root;
}

/**
 * The end-of-turn check is the only caller, and it runs at most once per turn,
 * so there is nothing for a cache to save and no stale result to invalidate.
 */
export function runWorkspaceClippy(root: string, timeoutMs: number, signal?: AbortSignal): Promise<CargoResult> {
	return runCargo(["clippy", "--workspace", "--all-targets", "--", "-D", "warnings"], root, timeoutMs, signal);
}

/**
 * The host's clippy slot for this user: a file in the system temporary
 * directory naming the Pi process that holds it. Every Pi lane a user runs on
 * a host runs its end-of-turn clippy through this slot, one at a time, because
 * each run already spreads the compiler over every core, and two at once only
 * compete for CPU and memory. The temporary directory is the host's, where the
 * Pi root is not: a lane host can give each lane its own
 * `PI_CODING_AGENT_DIR`.
 *
 * The name carries the user id because that directory is shared and sticky on
 * Linux and macOS: a slot another user's Pi left behind when it died cannot be
 * removed by this user, and one shared name would lock this user's check out
 * until a reboot. Windows gives each user a temporary directory of their own
 * and no user id, so the name there carries none.
 */
function clippySlotFile(): string {
	const uid = process.getuid?.();
	return uid === undefined ? "kendex-pi-hooks-clippy.slot" : `kendex-pi-hooks-clippy-${uid}.slot`;
}

/** How often a lane waiting for the slot looks again. */
const SLOT_POLL_MS = 250;

/**
 * Past its holder's own deadline, a slot is free whether or not the holder
 * released it: the holder's run is killed at that deadline, and this is the
 * second the kill escalation takes, and one more.
 */
const SLOT_GRACE_MS = 2000;

interface SlotHolder {
	pid: number;
	token: string;
	until: number;
}

/** What waiting for the slot came to. */
export type SlotClaim =
	| { kind: "held"; release: () => Promise<void> }
	| { kind: "busy" }
	| { kind: "aborted" }
	| { kind: "failed"; path: string; cause: string };

function errorCode(error: unknown): string | undefined {
	return (error as NodeJS.ErrnoException | undefined)?.code;
}

/**
 * Whether the holder's process still runs. The slot is this user's, so its
 * holder is a process this user can signal: EPERM is a pid the OS has since
 * given to another user's process, and the holder is as gone as on ESRCH.
 */
function pidAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

/**
 * The holder the slot file names, `null` where no file stands, or `stale`
 * where the file names no live holder: a holder process that is gone, one
 * past its own deadline (which also covers a pid the OS gave to another
 * process), or text that is no holder at all. A stale slot is free.
 */
async function readHolder(path: string): Promise<SlotHolder | null | "stale"> {
	let text: string;
	try {
		text = await readFile(path, "utf8");
	} catch (error) {
		if (errorCode(error) === "ENOENT") return null;
		throw error;
	}
	let holder: Partial<SlotHolder>;
	try {
		holder = JSON.parse(text) as Partial<SlotHolder>;
	} catch {
		return "stale";
	}
	if (typeof holder.pid !== "number" || typeof holder.token !== "string" || typeof holder.until !== "number") return "stale";
	if (holder.until < Date.now() || !pidAlive(holder.pid)) return "stale";
	return holder as SlotHolder;
}

function pause(ms: number, signal?: AbortSignal): Promise<void> {
	return new Promise((resolve) => {
		const done = () => {
			clearTimeout(timer);
			signal?.removeEventListener("abort", done);
			resolve();
		};
		const timer = setTimeout(done, ms);
		signal?.addEventListener("abort", done, { once: true });
	});
}

/**
 * Wait for this user's clippy slot until `deadline` (epoch ms). A holder writes
 * its record to a file of its own and links it into place, so the slot file
 * is complete the moment it exists and two lanes can never both create it.
 *
 * A stale slot is removed and claimed again. Two lanes that find the same
 * stale slot at the same instant can both remove it, and the second removal
 * can take the first lane's new claim with it; the cost is two runs at once
 * after a Pi process died holding the slot, never a lane locked out.
 *
 * The slot is a limit on load, not a lock on data, so a slot file that cannot
 * be written or read is `failed` and the caller says so rather than running.
 */
export async function claimClippySlot(deadline: number, signal?: AbortSignal): Promise<SlotClaim> {
	const path = join(tmpdir(), clippySlotFile());
	const token = `${process.pid}-${randomUUID()}`;
	const staged = `${path}.${token}`;
	try {
		await writeFile(staged, JSON.stringify({ pid: process.pid, token, until: deadline + SLOT_GRACE_MS }), { flag: "wx" });
	} catch (error) {
		return { kind: "failed", path: staged, cause: String(error) };
	}
	try {
		for (;;) {
			if (signal?.aborted) return { kind: "aborted" };
			try {
				await link(staged, path);
				return { kind: "held", release: () => releaseSlot(path, token) };
			} catch (error) {
				if (errorCode(error) !== "EEXIST") return { kind: "failed", path, cause: String(error) };
			}
			const holder = await readHolder(path);
			if (holder === null) continue;
			if (holder === "stale") {
				await unlink(path).catch((error: unknown) => {
					if (errorCode(error) !== "ENOENT") throw error;
				});
				continue;
			}
			if (Date.now() >= deadline) return { kind: "busy" };
			await pause(Math.min(SLOT_POLL_MS, Math.max(1, deadline - Date.now())), signal);
		}
	} catch (error) {
		return { kind: "failed", path, cause: String(error) };
	} finally {
		await unlink(staged).catch(() => {
			// The staged record is this process's own scratch; a slot claimed
			// or not, it names no holder anyone reads.
		});
	}
}

/** Free the slot if it is still this claim's: a waiter that judged it stale
 * may have taken it over, and that claim is not this one's to remove. */
async function releaseSlot(path: string, token: string): Promise<void> {
	try {
		const holder = JSON.parse(await readFile(path, "utf8")) as Partial<SlotHolder>;
		if (holder.token === token) await unlink(path);
	} catch {
		// Gone or taken over already: either way the slot is no longer this
		// claim's, and a waiter reads a leftover as stale at its deadline.
	}
}

export function filterLinesContaining(output: string, needle: string, limit = 10): string[] {
	return output
		.split("\n")
		.filter((line) => line.includes(needle))
		.slice(0, limit);
}

export function filterClippyErrors(output: string, limit = 15): string[] {
	return output
		.split("\n")
		.filter((line) => /^error/i.test(line.trim()))
		.slice(0, limit);
}
