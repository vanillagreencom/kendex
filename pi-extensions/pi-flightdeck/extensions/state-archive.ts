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

export function listTerminatedArchives(stateDir: string, sessionName: string): string[] {
	let entries: string[];
	try {
		entries = readdirSync(stateDir);
	} catch {
		return [];
	}
	const prefix = `flightdeck-state-${sessionName}-`;
	const suffix = ".json.archive";
	return entries
		.filter((name) => name.startsWith(prefix) && name.endsWith(suffix))
		.sort((a, b) => b.localeCompare(a))
		.map((name) => join(stateDir, name));
}

export function findNewestTerminatedArchive(stateDir: string, sessionName: string): string | undefined {
	return listTerminatedArchives(stateDir, sessionName)[0];
}
