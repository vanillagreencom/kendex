/**
 * Lane file retention: the one rule for files a Pi extension package keeps on
 * disk for a lane (fetched text, transcripts, task logs). A lane's files are
 * deleted once the lane's working directory is gone, which is how a merged
 * lane's worktree ends, and no file is kept past LANE_FILE_MAX_AGE_MS.
 *
 * Vendored byte-identical into every package that keeps such files, under
 * `scripts/`; pi-extensions/package-policy.test.mjs holds the copies equal.
 * Edit one copy, then copy it over the others.
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
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

/** Each existing `root/<entry>/<...below>` directory: the lane directories one
 *  package keeps under a root with one entry per session. An absent root has
 *  no lane directories. */
export function laneDirsUnder(root: string, ...below: string[]): string[] {
	let entries: string[];
	try {
		entries = readdirSync(root);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
		throw error;
	}
	return entries.map((entry) => join(root, entry, ...below)).filter((dir) => {
		try {
			return statSync(dir).isDirectory();
		} catch {
			return false;
		}
	});
}

function message(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

function remove(path: string, result: LanePruneResult): void {
	try {
		rmSync(path, { recursive: true, force: true });
		result.removed.push(path);
	} catch (error) {
		result.failed.push({ path, error: message(error) });
	}
}

function recordedCwd(dir: string): string | undefined {
	try {
		const cwd = readFileSync(join(dir, LANE_CWD_FILE), "utf8").trim();
		return cwd || undefined;
	} catch {
		return undefined;
	}
}

/** Remove the files under `dir` older than `cutoff`; return how many remain. */
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
		if (entry.isDirectory()) {
			if (pruneOldFiles(path, cutoff, result) === 0) remove(path, result);
			else remaining++;
			continue;
		}
		let mtime: number;
		try {
			mtime = statSync(path).mtimeMs;
		} catch (error) {
			result.failed.push({ path, error: message(error) });
			remaining++;
			continue;
		}
		if (mtime < cutoff) remove(path, result);
		else remaining++;
	}
	return remaining;
}

/**
 * Apply the retention rule to each lane directory in `laneDirs`. A directory
 * whose recorded working directory is gone is removed whole. Otherwise each
 * file older than LANE_FILE_MAX_AGE_MS is removed, and the directory goes too
 * once nothing is left in it. A failed removal is reported, never thrown, so
 * one unreadable lane does not stop the rest.
 */
export function pruneLaneDirs(laneDirs: string[], now = Date.now()): LanePruneResult {
	const result: LanePruneResult = { removed: [], failed: [] };
	const cutoff = now - LANE_FILE_MAX_AGE_MS;
	for (const dir of laneDirs) {
		const cwd = recordedCwd(dir);
		if (cwd !== undefined && !existsSync(cwd)) {
			remove(dir, result);
			continue;
		}
		if (pruneOldFiles(dir, cutoff, result) === 0) remove(dir, result);
	}
	return result;
}
