// vstack#213: daemon staleness metadata.
//
// Written by the daemon at start (and refreshed each time reconcile
// mutates the subscriber set) so external tooling can answer
// "is this daemon's argv still aligned with the active run / live
// tracked entries?" without re-parsing /proc/<pid>/cmdline.
//
// Consumers:
//   - flightdeck-session ensure_daemon_for_session decides whether to
//     leave the daemon alone, stop it, or spawn fresh.
//   - flightdeck-daemon health surfaces the snapshot + a derived
//     staleness enum for operator triage.

import { mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export interface DaemonMeta {
	schema_version: 1;
	pid: number;
	session_id: string;
	session_key: string;
	session_name: string;
	started_at: string;
	master_pane_id: string;
	master_harness: string;
	inner_targets: string[];
	inner_harnesses: string[];
	subscribed_pane_ids: string[];
	state_file_path: string;
	state_file_inode: string | null;
	active_run_id: string | null;
	updated_at: string;
}

export type DaemonStaleness =
	| "fresh"
	| "stale-state"     // state file replaced (inode/path changed)
	| "stale-inner"     // subscribed set drifted from live tracked entries
	| "pre-active-run"; // recorded run id no longer matches active run

export interface DaemonStalenessInput {
	stateFilePath: string;
	stateFileInode: string | null;
	activeRunId: string | null;
	livePaneIds: readonly string[];
}

export function classifyStaleness(meta: DaemonMeta, input: DaemonStalenessInput): DaemonStaleness {
	if (meta.state_file_path !== input.stateFilePath) return "stale-state";
	if (meta.state_file_inode !== null && input.stateFileInode !== null
		&& meta.state_file_inode !== input.stateFileInode) return "stale-state";
	if (meta.active_run_id !== null && input.activeRunId !== null
		&& meta.active_run_id !== input.activeRunId) return "pre-active-run";
	const subscribed = new Set(meta.subscribed_pane_ids);
	for (const pid of input.livePaneIds) {
		if (!subscribed.has(pid)) return "stale-inner";
	}
	return "fresh";
}

export function readDaemonMeta(path: string): DaemonMeta | null {
	let text: string;
	try { text = readFileSync(path, "utf8"); }
	catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
		throw error;
	}
	let parsed: unknown;
	try { parsed = JSON.parse(text); }
	catch { return null; }
	if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
	const raw = parsed as Record<string, unknown>;
	if (raw.schema_version !== 1) return null;
	const stringField = (k: string): string => typeof raw[k] === "string" ? raw[k] as string : "";
	const numField = (k: string): number => typeof raw[k] === "number" && Number.isFinite(raw[k]) ? raw[k] as number : 0;
	const stringArr = (k: string): string[] => Array.isArray(raw[k])
		? (raw[k] as unknown[]).filter((v): v is string => typeof v === "string")
		: [];
	const nullableString = (k: string): string | null => {
		const v = raw[k];
		if (typeof v === "string") return v;
		return null;
	};
	return {
		active_run_id: nullableString("active_run_id"),
		inner_harnesses: stringArr("inner_harnesses"),
		inner_targets: stringArr("inner_targets"),
		master_harness: stringField("master_harness"),
		master_pane_id: stringField("master_pane_id"),
		pid: numField("pid"),
		schema_version: 1,
		session_id: stringField("session_id"),
		session_key: stringField("session_key"),
		session_name: stringField("session_name"),
		started_at: stringField("started_at"),
		state_file_inode: nullableString("state_file_inode"),
		state_file_path: stringField("state_file_path"),
		subscribed_pane_ids: stringArr("subscribed_pane_ids"),
		updated_at: stringField("updated_at"),
	};
}

export function writeDaemonMeta(path: string, meta: DaemonMeta): void {
	mkdirSync(dirname(path), { recursive: true });
	const tmp = `${path}.tmp.${process.pid}`;
	try {
		writeFileSync(tmp, `${JSON.stringify(meta, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
		renameSync(tmp, path);
	} catch (error) {
		try { require("node:fs").unlinkSync(tmp); } catch { /* */ }
		throw error;
	}
}

export function statInode(path: string): string | null {
	try { return String(statSync(path).ino); }
	catch { return null; }
}
