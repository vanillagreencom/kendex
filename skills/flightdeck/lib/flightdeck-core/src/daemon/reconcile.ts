// Mid-session reconciliation of tracked entries against the daemon's
// active subscriber set (vstack#59).
//
// The bash daemon's run loop reads `--inner` once at startup. Entries
// added later (e.g. an adhoc Pi pane spawned mid-session) are invisible
// until the daemon restarts. Reconciliation makes the daemon a first-
// class observer of state changes: each tick it queries the registry,
// spawns subscribers for new panes, and reaps subscribers for entries
// that disappeared.
//
// This module is intentionally pure: the daemon loop wires concrete
// pane-registry / spawn / reap callbacks at construction time, while
// tests drive the function with deterministic in-memory deps.

export const RECONCILE_DEFAULT_INTERVAL_SEC = 5;

export interface ReconcileEntry {
	paneId: string;
	harness: string;
	kind?: string;
	cwd?: string;
	adapterMeta?: ReconcileAdapterMeta;
}

export interface ReconcileAdapterMeta {
	ocUrl?: string;
	ocSessionId?: string;
	ccTranscript?: string;
	piPid?: string;
	piSocket?: string;
	piSessionId?: string;
	cxUrl?: string;
	cxThreadId?: string;
}

export interface ReconcileDeps {
	listTrackedEntries: () => ReconcileEntry[];
	activePaneIds: () => Iterable<string>;
	spawnFor: (entry: ReconcileEntry) => { spawned: boolean; reason?: string };
	reap: (paneId: string) => void;
	log: (tag: string, msg: string) => void;
	now?: () => number;
}

export interface ReconcileResult {
	added: string[];
	reaped: string[];
	skipped: { paneId: string; reason: string }[];
}

export function reconcileTrackedEntries(deps: ReconcileDeps): ReconcileResult {
	const result: ReconcileResult = { added: [], reaped: [], skipped: [] };
	let entries: ReconcileEntry[];
	try {
		entries = deps.listTrackedEntries();
	} catch (err) {
		deps.log("reconcile-error", `listTrackedEntries threw: ${(err as Error)?.message ?? err}`);
		return result;
	}
	const seen = new Set<string>();
	const active = new Set<string>();
	for (const id of deps.activePaneIds()) active.add(id);
	for (const entry of entries) {
		if (!entry?.paneId) continue;
		if (seen.has(entry.paneId)) continue;
		seen.add(entry.paneId);
		if (active.has(entry.paneId)) continue;
		try {
			const outcome = deps.spawnFor(entry);
			if (outcome.spawned) result.added.push(entry.paneId);
			else result.skipped.push({ paneId: entry.paneId, reason: outcome.reason ?? "skipped" });
		} catch (err) {
			deps.log("reconcile-spawn-error", `pane=${entry.paneId} harness=${entry.harness}: ${(err as Error)?.message ?? err}`);
			result.skipped.push({ paneId: entry.paneId, reason: "spawn-threw" });
		}
	}
	for (const paneId of active) {
		if (seen.has(paneId)) continue;
		try {
			deps.reap(paneId);
			result.reaped.push(paneId);
		} catch (err) {
			deps.log("reconcile-reap-error", `pane=${paneId}: ${(err as Error)?.message ?? err}`);
		}
	}
	if (result.added.length > 0 || result.reaped.length > 0) {
		deps.log(
			"reconcile",
			`added=${result.added.length} reaped=${result.reaped.length} added_ids=${result.added.join(",") || "-"} reaped_ids=${result.reaped.join(",") || "-"}`,
		);
	}
	return result;
}

export function reconcileIntervalFromEnv(env: NodeJS.ProcessEnv = process.env): number {
	const raw = env.FD_RECONCILE_INTERVAL_SEC?.trim();
	const parsed = raw ? Number(raw) : Number.NaN;
	if (!Number.isFinite(parsed) || parsed < 0) return RECONCILE_DEFAULT_INTERVAL_SEC;
	return parsed;
}
