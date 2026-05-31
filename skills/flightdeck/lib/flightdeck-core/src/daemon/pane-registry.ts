// pane-registry helpers extracted from daemon/loop.ts (W5 reviewer-structure
// follow-up B4). These are pure adapters over the `pane-registry` CLI:
// shell out, parse JSON, return typed rows. Keeping them in loop.ts pushed
// it past 800 lines for no reason — the helpers don't reference any loop
// state, so they belong in their own file.

import { spawnSync, type SpawnSyncReturns } from "node:child_process";

import type { ReconcileAdapterMeta, ReconcileEntry } from "./reconcile.ts";

const PANE_REGISTRY_READ_TIMEOUT_DEFAULT_SEC = 5;

export function paneRegistryReadTimeoutMs(env: NodeJS.ProcessEnv = process.env): number {
	const raw = env.FD_PANE_REGISTRY_READ_TIMEOUT_SEC ?? String(PANE_REGISTRY_READ_TIMEOUT_DEFAULT_SEC);
	const parsed = Number.parseFloat(raw);
	if (!Number.isFinite(parsed) || parsed <= 0) return PANE_REGISTRY_READ_TIMEOUT_DEFAULT_SEC * 1000;
	return Math.ceil(parsed * 1000);
}

function runPaneRegistry(bin: string, args: string[]): SpawnSyncReturns<string> {
	return spawnSync(bin, args, { encoding: "utf8", killSignal: "SIGKILL", timeout: paneRegistryReadTimeoutMs() });
}

export interface RefreshWindowNameWarning {
	id?: string;
	reason: string;
	message: string;
}

export type RefreshTrackedWindowNamesResult =
	| { ok: true; updated: string[]; cleared: string[]; warnings: RefreshWindowNameWarning[] }
	| { ok: false; reason: string; message: string };

export function paneRegistryArgs(bin: string, action: string, issue: string): string {
	const r = runPaneRegistry(bin, [action, issue]);
	if (r.status !== 0) return "";
	return (r.stdout ?? "").trim();
}

export function paneRegistryIssueForPane(bin: string, paneTarget: string): string {
	const r = runPaneRegistry(bin, ["find-by-pane", paneTarget]);
	if (r.status !== 0) return "";
	const raw = (r.stdout ?? "").trim();
	if (!raw.startsWith("{")) return raw;
	try {
		const parsed = JSON.parse(raw) as { id?: unknown };
		return typeof parsed.id === "string" ? parsed.id : "";
	} catch {
		return "";
	}
}

export function extractFlag(args: string, flag: string): string {
	const tokens = args.split(/\s+/);
	for (let i = 0; i < tokens.length - 1; i += 1) {
		if (tokens[i] === flag) return tokens[i + 1] ?? "";
	}
	return "";
}

export function resolveMeta(bin: string, action: string, paneTarget: string): string {
	const issue = paneRegistryIssueForPane(bin, paneTarget);
	if (!issue) return "";
	return paneRegistryArgs(bin, action, issue);
}

export function paneRegistryRows(bin: string): Record<string, unknown>[] {
	if (!bin) return [];
	const r = runPaneRegistry(bin, ["list", "--format", "json"]);
	if (r.status !== 0) return [];
	try {
		const rows = JSON.parse(r.stdout ?? "[]") as unknown;
		if (!Array.isArray(rows)) return [];
		return rows.filter((row): row is Record<string, unknown> => !!row && typeof row === "object" && !Array.isArray(row));
	} catch { return []; }
}

export interface LiveInnerArgsForHandoff {
	innerTargets: string[];
	innerHarnesses: string[];
	source: "live" | "fallback";
	warnings: string[];
}

export interface FallbackInnerArgs {
	innerTargets: string[];
	innerHarnesses: string[];
}

interface LiveInnerRow {
	pane_id?: unknown;
	harness?: unknown;
}

function normalizeFallback(fallback: FallbackInnerArgs): FallbackInnerArgs {
	return {
		innerTargets: fallback.innerTargets.filter(Boolean),
		innerHarnesses: fallback.innerHarnesses.length === fallback.innerTargets.length ? fallback.innerHarnesses : [],
	};
}

function paneRegistryLiveInnerRows(bin: string): { ok: true; rows: LiveInnerRow[] } | { ok: false; error: string } {
	if (!bin) return { ok: false, error: "pane-registry binary missing" };
	const r = runPaneRegistry(bin, ["list", "--format", "inner-live-json"]);
	if (r.status !== 0 || r.error) {
		const stderr = (r.stderr ?? "").trim();
		const error = r.error ? r.error.message : `exit ${r.status ?? "unknown"}${stderr ? `: ${stderr}` : ""}`;
		return { ok: false, error };
	}
	try {
		const parsed = JSON.parse(r.stdout ?? "[]") as unknown;
		if (!Array.isArray(parsed)) return { ok: false, error: "inner-live-json did not return an array" };
		return { ok: true, rows: parsed.filter((row): row is LiveInnerRow => !!row && typeof row === "object" && !Array.isArray(row)) };
	} catch (err) {
		return { ok: false, error: `invalid inner-live-json: ${(err as Error)?.message ?? err}` };
	}
}

export function liveInnerArgsForHandoff(bin: string, fallback: FallbackInnerArgs): LiveInnerArgsForHandoff {
	const warnings: string[] = [];
	const live = paneRegistryLiveInnerRows(bin);
	if (!live.ok) {
		warnings.push(`pane-registry list --format inner-live-json failed: ${live.error}; preserving current inner pane set`);
		return { ...normalizeFallback(fallback), source: "fallback", warnings };
	}

	const innerTargets: string[] = [];
	const innerHarnesses: string[] = [];
	for (const row of live.rows) {
		const paneId = typeof row.pane_id === "string" ? row.pane_id.trim() : "";
		if (!paneId) continue;
		innerTargets.push(paneId);
		innerHarnesses.push(typeof row.harness === "string" ? row.harness.trim() : "");
	}
	return { innerTargets, innerHarnesses, source: "live", warnings };
}

export function resolvePaneTargetForEntry(bin: string, paneId: string): string {
	if (!paneId) return "";
	for (const row of paneRegistryRows(bin)) {
		if (row.pane_id === paneId) {
			if (typeof row.pane_target === "string" && row.pane_target) return row.pane_target;
			return paneId;
		}
	}
	return paneId;
}

function spawnErrorMessage(r: ReturnType<typeof spawnSync>): string {
	if (r.error) return r.error.message;
	const stderr = String(r.stderr ?? "").trim();
	return stderr || "no stderr";
}

export function refreshTrackedWindowNames(bin: string): RefreshTrackedWindowNamesResult {
	if (!bin) return { ok: false, reason: "missing-command", message: "pane-registry command path is empty" };
	const r = runPaneRegistry(bin, ["refresh-window-names"]);
	if (r.error) return { ok: false, reason: "spawn-failed", message: `pane-registry refresh-window-names spawn failed: ${r.error.message}` };
	if (r.status !== 0) return { ok: false, reason: "command-failed", message: `pane-registry refresh-window-names failed (status=${r.status}): ${spawnErrorMessage(r)}` };
	try {
		const parsed = JSON.parse(r.stdout ?? "{}") as unknown;
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { ok: false, reason: "invalid-json", message: "pane-registry refresh-window-names returned non-object JSON" };
		const obj = parsed as Record<string, unknown>;
		const stderr = String(r.stderr ?? "").trim();
		const warnings = Array.isArray(obj.warnings)
			? obj.warnings.filter((warning): warning is Record<string, unknown> => !!warning && typeof warning === "object" && !Array.isArray(warning)).map((warning) => ({
				id: typeof warning.id === "string" ? warning.id : undefined,
				message: typeof warning.message === "string" ? warning.message : "missing warning message",
				reason: typeof warning.reason === "string" ? warning.reason : "unknown",
			}))
			: [];
		if (stderr) warnings.unshift({ id: undefined, message: stderr, reason: "command-stderr" });
		return {
			ok: true,
			cleared: Array.isArray(obj.cleared) ? obj.cleared.filter((id): id is string => typeof id === "string") : [],
			warnings,
			updated: Array.isArray(obj.updated) ? obj.updated.filter((id): id is string => typeof id === "string") : [],
		};
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { ok: false, reason: "invalid-json", message: `pane-registry refresh-window-names returned invalid JSON: ${message}` };
	}
}

export function entryKindForPane(bin: string, paneId: string): string {
	if (!paneId) return "";
	for (const row of paneRegistryRows(bin)) {
		if (row.pane_id === paneId && typeof row.kind === "string" && row.kind.trim()) return row.kind.trim();
	}
	return "";
}

export function listTrackedEntriesForReconcile(bin: string, defaultHarness: string): ReconcileEntry[] {
	if (!bin) return [];
	const r = runPaneRegistry(bin, ["list", "--format", "json"]);
	if (r.error) throw new Error(`pane-registry list spawn failed: ${r.error.message}`);
	if (r.status !== 0) throw new Error(`pane-registry list failed (status=${r.status ?? "unknown"}): ${(r.stderr ?? "").trim() || "no stderr"}`);
	let rows: unknown;
	try { rows = JSON.parse(r.stdout ?? "[]"); }
	catch (err) { throw new Error(`pane-registry list returned invalid JSON: ${(err as Error)?.message ?? err}`); }
	if (!Array.isArray(rows)) throw new Error("pane-registry list returned non-array JSON");
	const entries: ReconcileEntry[] = [];
	for (const row of rows) {
		if (!row || typeof row !== "object") continue;
		const r2 = row as Record<string, unknown>;
		const paneId = typeof r2.pane_id === "string" ? r2.pane_id : "";
		if (!paneId) continue;
		const harness = typeof r2.harness === "string" && r2.harness.trim() ? r2.harness.trim() : (defaultHarness || "");
		const kind = typeof r2.kind === "string" ? r2.kind : undefined;
		const cwd = typeof r2.cwd === "string" ? r2.cwd : undefined;
		const adapterMeta: ReconcileAdapterMeta = {
			ocUrl: typeof r2.oc_url === "string" ? r2.oc_url : undefined,
			ocSessionId: typeof r2.oc_session_id === "string" ? r2.oc_session_id : undefined,
			ccTranscript: typeof r2.cc_transcript === "string" ? r2.cc_transcript : undefined,
			piPid: r2.pi_bridge_pid != null ? String(r2.pi_bridge_pid) : undefined,
			piSocket: typeof r2.pi_bridge_socket === "string" ? r2.pi_bridge_socket : undefined,
			piSessionId: typeof r2.pi_session_id === "string" ? r2.pi_session_id : undefined,
			cxUrl: typeof r2.cx_ws === "string" ? r2.cx_ws : undefined,
			cxThreadId: typeof r2.cx_thread_id === "string" ? r2.cx_thread_id : undefined,
		};
		entries.push({ paneId, harness, kind, cwd, adapterMeta });
	}
	return entries;
}
