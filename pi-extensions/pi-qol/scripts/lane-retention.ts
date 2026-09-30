/**
 * Lane file retention: the one rule for files a Pi extension package keeps on
 * disk for a lane (fetched text, transcripts, task logs). A lane's files are
 * deleted once the lane's working directory is gone, which is how a merged
 * lane's worktree ends, and no file is kept past LANE_FILE_MAX_AGE_MS.
 *
 * A lane directory is one the package made with openLaneDir: a real directory,
 * owned by this user, that holds a LANE_CWD_FILE record. The prune touches
 * nothing else under its root, so a folder another tool keeps there, or a
 * symbolic link to one, is left alone.
 *
 * Vendored byte-identical into every package that keeps such files, under
 * `scripts/`; pi-extensions/package-policy.test.mjs holds the copies equal.
 * Edit one copy, then copy it over the others.
 */
import { lstatSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const LANE_FILE_MAX_AGE_MS = 5 * 24 * 60 * 60 * 1000;

/** The file in a lane directory that names the lane's working directory. */
export const LANE_CWD_FILE = ".lane-cwd";

export interface LanePruneFailure {
	path: string;
	error: string;
}

export interface LanePruneResult {
	removed: string[];
	failed: LanePruneFailure[];
}

/** Create `dir` as a lane directory for `cwd`. Rewriting the record marks the
 *  lane live, so its directory is not pruned as empty and old. */
export function openLaneDir(dir: string, cwd: string): string {
	mkdirSync(dir, { recursive: true, mode: 0o700 });
	writeFileSync(join(dir, LANE_CWD_FILE), cwd, { mode: 0o600 });
	return dir;
}

function message(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

/** Whether `path` is a real directory, not a symbolic link, owned by this
 *  user. A platform without user ids (Windows) checks the type alone. */
function ownDirectory(path: string): boolean {
	let stat;
	try {
		stat = lstatSync(path);
	} catch {
		return false;
	}
	const uid = process.getuid?.();
	return stat.isDirectory() && (uid === undefined || stat.uid === uid);
}

function remove(path: string, result: LanePruneResult): void {
	try {
		rmSync(path, { recursive: true, force: true });
		result.removed.push(path);
	} catch (error) {
		result.failed.push({ path, error: message(error) });
	}
}

/** The lane's recorded working directory; undefined when `dir` holds no
 *  record, so the package did not make it. */
function recordedCwd(dir: string): string | undefined {
	try {
		const cwd = readFileSync(join(dir, LANE_CWD_FILE), "utf8");
		return cwd === "" ? undefined : cwd;
	} catch {
		return undefined;
	}
}

/** Whether a lane's recorded working directory is still there. Only a stat
 *  that answers ENOENT or ENOTDIR confirms it is gone. Any other failure, such
 *  as a refused permission or a filesystem that is briefly unavailable, is
 *  reported against the lane and answers "unknown", so the lane is not
 *  removed as gone. */
function cwdState(dir: string, cwd: string, result: LanePruneResult): "present" | "gone" | "unknown" {
	try {
		statSync(cwd);
		return "present";
	} catch (error) {
		const code = (error as NodeJS.ErrnoException).code;
		if (code === "ENOENT" || code === "ENOTDIR") return "gone";
		result.failed.push({ path: dir, error: `lane-cwd-unchecked: the lane is kept; its working directory could not be checked: ${message(error)}` });
		return "unknown";
	}
}

function modifiedAt(path: string, result: LanePruneResult): number | undefined {
	try {
		return lstatSync(path).mtimeMs;
	} catch (error) {
		result.failed.push({ path, error: message(error) });
		return undefined;
	}
}

/** Remove the files under `dir` older than `cutoff`, never the lane record;
 *  return how many entries other than the record remain. */
function pruneOldFiles(dir: string, cutoff: number, result: LanePruneResult): number {
	let remaining = 0;
	let entries;
	try {
		entries = readdirSync(dir, { withFileTypes: true });
	} catch (error) {
		result.failed.push({ path: dir, error: message(error) });
		return 1;
	}
	for (const entry of entries) {
		const path = join(dir, entry.name);
		if (entry.name === LANE_CWD_FILE) continue;
		if (entry.isDirectory()) {
			if (pruneOldFiles(path, cutoff, result) === 0) remove(path, result);
			else remaining++;
			continue;
		}
		const mtime = modifiedAt(path, result);
		if (mtime !== undefined && mtime < cutoff) remove(path, result);
		else remaining++;
	}
	return remaining;
}

/**
 * Apply the retention rule to each lane directory at `root/<entry>/<...below>`,
 * one entry per session. A lane whose recorded working directory is gone is
 * removed whole; a working directory that cannot be checked is reported and
 * does not count as gone. Otherwise each file older than LANE_FILE_MAX_AGE_MS is
 * removed, and the lane goes too once only its record is left and the record
 * is that old. The record is kept while the lane is: it is what marks the
 * directory as the package's. An absent root has no lanes. Every failure,
 * including an unreadable root, is reported, never thrown, so the caller's
 * other session_start work still runs.
 */
export function pruneLanes(root: string, below: string[] = [], now = Date.now()): LanePruneResult {
	const result: LanePruneResult = { removed: [], failed: [] };
	let entries: string[];
	try {
		entries = readdirSync(root);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "ENOENT") result.failed.push({ path: root, error: message(error) });
		return result;
	}
	if (!ownDirectory(root)) {
		result.failed.push({ path: root, error: "lane-root-not-owned: not a directory this user owns; nothing under it was pruned" });
		return result;
	}
	const cutoff = now - LANE_FILE_MAX_AGE_MS;
	for (const entry of entries) {
		let dir = root;
		let owned = true;
		for (const part of [entry, ...below]) {
			dir = join(dir, part);
			if (!ownDirectory(dir)) {
				owned = false;
				break;
			}
		}
		if (!owned) continue;
		const cwd = recordedCwd(dir);
		if (cwd === undefined) continue;
		const state = cwdState(dir, cwd, result);
		switch (state) {
			case "gone":
				remove(dir, result);
				continue;
			case "present":
			case "unknown":
				break;
			default: {
				const unhandled: never = state;
				throw new Error(`lane-cwd-state-unhandled: ${String(unhandled)}`);
			}
		}
		if (pruneOldFiles(dir, cutoff, result) > 0) continue;
		const recordAt = modifiedAt(join(dir, LANE_CWD_FILE), result);
		if (recordAt !== undefined && recordAt < cutoff) remove(dir, result);
	}
	return result;
}
