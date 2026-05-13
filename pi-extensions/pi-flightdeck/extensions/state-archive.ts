// Archive discovery for the post-termination dashboard view (issue #17).
//
// `flightdeck-state archive` renames the live `flightdeck-state-<SESSION>.json`
// to `flightdeck-state-<SESSION>-<TERMINATED_AT>.json.archive`. After that
// rename, `pi-flightdeck` has no live file to read; without an explicit
// archive fallback it would collapse to `inactive` and the user would lose
// the completed-session view.
//
// Filenames embed `terminated_at` in ISO `YYYYMMDDTHHMMSSZ` form (see
// `flightdeck-state archive`), so a lexicographic sort is a sound proxy for
// newest-first ordering.

import { readdirSync } from "node:fs";
import { join } from "node:path";

export interface ArchiveDirError {
	code: string;
	path: string;
	message: string;
}

export interface ListTerminatedArchivesResult {
	archives: string[];
	// Set only when `readdirSync` failed with a non-ENOENT error
	// (permission denied, IO failure, etc.). ENOENT — the dir does not
	// exist — collapses to `{ archives: [], error: undefined }` so a
	// project that never had a tmp/ directory renders inactive, not
	// archive-error.
	error?: ArchiveDirError;
}

export function listTerminatedArchives(stateDir: string, sessionName: string): ListTerminatedArchivesResult {
	let entries: string[];
	try {
		entries = readdirSync(stateDir);
	} catch (e) {
		const err = e as NodeJS.ErrnoException;
		if (err.code === "ENOENT") return { archives: [] };
		return {
			archives: [],
			error: {
				code: err.code ?? "EUNKNOWN",
				message: err.message ?? String(e),
				path: stateDir,
			},
		};
	}
	const prefix = `flightdeck-state-${sessionName}-`;
	const suffix = ".json.archive";
	const archives = entries
		.filter((name) => name.startsWith(prefix) && name.endsWith(suffix))
		.sort((a, b) => b.localeCompare(a))
		.map((name) => join(stateDir, name));
	return { archives };
}

export function findNewestTerminatedArchive(stateDir: string, sessionName: string): string | undefined {
	return listTerminatedArchives(stateDir, sessionName).archives[0];
}
