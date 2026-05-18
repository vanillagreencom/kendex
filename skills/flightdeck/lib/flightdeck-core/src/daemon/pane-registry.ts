// pane-registry helpers extracted from daemon/loop.ts (W5 reviewer-structure
// follow-up B4). These are pure adapters over the `pane-registry` CLI:
// shell out, parse JSON, return typed rows. Keeping them in loop.ts pushed
// it past 800 lines for no reason — the helpers don't reference any loop
// state, so they belong in their own file.

import { spawnSync } from "node:child_process";

import type { ReconcileAdapterMeta, ReconcileEntry } from "./reconcile.ts";

export function paneRegistryArgs(bin: string, action: string, issue: string): string {
	const r = spawnSync(bin, [action, issue], { encoding: "utf8" });
	if (r.status !== 0) return "";
	return (r.stdout ?? "").trim();
}

export function paneRegistryIssueForPane(bin: string, paneTarget: string): string {
	const r = spawnSync(bin, ["find-by-pane", paneTarget], { encoding: "utf8" });
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
	const r = spawnSync(bin, ["list", "--format", "json"], { encoding: "utf8" });
	if (r.status !== 0) return [];
	try {
		const rows = JSON.parse(r.stdout ?? "[]") as unknown;
		if (!Array.isArray(rows)) return [];
		return rows.filter((row): row is Record<string, unknown> => !!row && typeof row === "object" && !Array.isArray(row));
	} catch { return []; }
}

function splitCsv(csv: string, opts: { preserveEmpty?: boolean } = {}): string[] {
	const trimmed = csv.trim();
	if (!trimmed) return [];
	const items = trimmed.split(",").map((item) => item.trim());
	return opts.preserveEmpty ? items : items.filter(Boolean);
}

function paneRegistryListFormat(bin: string, format: string, opts: { preserveEmpty?: boolean } = {}): { ok: boolean; values: string[]; error?: string } {
	if (!bin) return { ok: false, values: [], error: "pane-registry binary missing" };
	const r = spawnSync(bin, ["list", "--format", format], { encoding: "utf8" });
	if (r.status !== 0 || r.error) {
		const stderr = (r.stderr ?? "").trim();
		const error = r.error ? r.error.message : `exit ${r.status ?? "unknown"}${stderr ? `: ${stderr}` : ""}`;
		return { ok: false, values: [], error };
	}
	return { ok: true, values: splitCsv(r.stdout ?? "", opts) };
}

export interface LiveInnerArgsForHandoff {
	innerTargets: string[];
	innerHarnesses: string[];
	warnings: string[];
}

export function liveInnerArgsForHandoff(bin: string): LiveInnerArgsForHandoff {
	const warnings: string[] = [];
	const panes = paneRegistryListFormat(bin, "inner-panes-live");
	if (!panes.ok) warnings.push(`pane-registry list --format inner-panes-live failed: ${panes.error ?? "unknown error"}`);
	const harnesses = paneRegistryListFormat(bin, "inner-harnesses-live", { preserveEmpty: true });
	if (!harnesses.ok) warnings.push(`pane-registry list --format inner-harnesses-live failed: ${harnesses.error ?? "unknown error"}`);

	const innerTargets = panes.ok ? panes.values : [];
	let innerHarnesses = harnesses.ok ? harnesses.values : [];
	if (innerHarnesses.length > 0 && innerHarnesses.length !== innerTargets.length) {
		warnings.push(`live inner harness count ${innerHarnesses.length} did not match pane count ${innerTargets.length}; dropping harness override`);
		innerHarnesses = [];
	}
	return { innerTargets, innerHarnesses, warnings };
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

export function entryKindForPane(bin: string, paneId: string): string {
	if (!paneId) return "";
	for (const row of paneRegistryRows(bin)) {
		if (row.pane_id === paneId && typeof row.kind === "string" && row.kind.trim()) return row.kind.trim();
	}
	return "";
}

export function listTrackedEntriesForReconcile(bin: string, defaultHarness: string): ReconcileEntry[] {
	if (!bin) return [];
	const r = spawnSync(bin, ["list", "--format", "json"], { encoding: "utf8" });
	if (r.status !== 0) return [];
	let rows: unknown;
	try { rows = JSON.parse(r.stdout ?? "[]"); }
	catch { return []; }
	if (!Array.isArray(rows)) return [];
	const entries: ReconcileEntry[] = [];
	for (const row of rows) {
		if (!row || typeof row !== "object") continue;
		const r2 = row as Record<string, unknown>;
		const paneId = typeof r2.pane_id === "string" ? r2.pane_id : "";
		if (!paneId) continue;
		const harness = typeof r2.harness === "string" && r2.harness.trim() ? r2.harness.trim() : (defaultHarness || "");
		const kind = typeof r2.kind === "string" ? r2.kind : undefined;
		const adapterMeta: ReconcileAdapterMeta = {
			ocUrl: typeof r2.oc_url === "string" ? r2.oc_url : undefined,
			ocSessionId: typeof r2.oc_session_id === "string" ? r2.oc_session_id : undefined,
			ccTranscript: typeof r2.cc_transcript === "string" ? r2.cc_transcript : undefined,
			piPid: r2.pi_bridge_pid != null ? String(r2.pi_bridge_pid) : undefined,
			piSocket: typeof r2.pi_bridge_socket === "string" ? r2.pi_bridge_socket : undefined,
			cxUrl: typeof r2.cx_ws === "string" ? r2.cx_ws : undefined,
			cxThreadId: typeof r2.cx_thread_id === "string" ? r2.cx_thread_id : undefined,
		};
		entries.push({ paneId, harness, kind, adapterMeta });
	}
	return entries;
}
