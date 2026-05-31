import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";

import { readTrackedEntries } from "../state/tracked-entry.ts";
import type { FlightdeckStateLike, TrackedEntry } from "../state/types.ts";

export const MERGE_PERMISSION_BLOCKED_TAG = "merge-permission-blocked";
export const MERGE_PERMISSION_MONITOR_REASON = "merge-permission-monitor";
export const MERGE_PERMISSION_MONITOR_INTERVAL_SEC = 60;

export interface MergePermissionWakeCandidate {
	key: string;
	paneId: string;
	hash: string;
	entryId: string;
	domainKey: "issue" | "github_issue" | "plan_item";
	pr: number;
	details: {
		event_type: typeof MERGE_PERMISSION_MONITOR_REASON;
		entry_id: string;
		domain_key: "issue" | "github_issue" | "plan_item";
		pr: number;
		interval_sec: number;
		scheduled: true;
	};
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === "object" && !Array.isArray(value);
}

function finitePr(value: unknown): number | null {
	if (typeof value === "number" && Number.isFinite(value) && value > 0) return Math.trunc(value);
	if (typeof value === "string" && /^\d+$/.test(value.trim())) {
		const parsed = Number.parseInt(value.trim(), 10);
		return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
	}
	return null;
}

function domainFor(entry: TrackedEntry): { key: "issue" | "github_issue" | "plan_item"; value: Record<string, unknown> } | null {
	const domain = isRecord(entry.domain) ? entry.domain : null;
	if (!domain) return null;
	for (const key of ["issue", "github_issue", "plan_item"] as const) {
		const value = domain[key];
		if (isRecord(value)) return { key, value };
	}
	return null;
}

function hasMergeBlockedMarker(domain: Record<string, unknown>): boolean {
	return isRecord(domain.merge_blocked_permission) || domain.phase === "merge-blocked-permission";
}

function prFor(entry: TrackedEntry, domain: Record<string, unknown>): number | null {
	const marker = isRecord(domain.merge_blocked_permission) ? domain.merge_blocked_permission : null;
	return finitePr(marker?.pr) ?? finitePr(domain.pr_number) ?? finitePr(entry.pr_number);
}

function stateIsMonitorable(entry: TrackedEntry): boolean {
	const state = typeof entry.state === "string" && entry.state.trim() ? entry.state : "waiting";
	return state === "ready" || state === "merge-ready";
}

function monitorHash(key: string, nowSec: number, intervalSec: number): string {
	const bucket = Math.floor(nowSec / Math.max(1, intervalSec));
	return createHash("sha256")
		.update(`${MERGE_PERMISSION_MONITOR_REASON}\0${key}\0${bucket}`)
		.digest("hex")
		.slice(0, 12);
}

export function collectMergePermissionWakeCandidates(input: {
	state: FlightdeckStateLike | undefined | null;
	nowSec: number;
	intervalSec?: number;
	lastWakeByKey?: Map<string, number>;
	warn?: (message: string) => void;
}): MergePermissionWakeCandidate[] {
	const intervalSec = Math.max(1, Math.trunc(input.intervalSec ?? MERGE_PERMISSION_MONITOR_INTERVAL_SEC));
	const entries = readTrackedEntries(input.state, { warn: input.warn });
	const out: MergePermissionWakeCandidate[] = [];
	for (const entry of Object.values(entries)) {
		if (!stateIsMonitorable(entry)) continue;
		const domain = domainFor(entry);
		if (!domain || !hasMergeBlockedMarker(domain.value)) continue;
		const pr = prFor(entry, domain.value);
		if (!pr) continue;
		const key = `${entry.id}:${domain.key}:${pr}`;
		const last = input.lastWakeByKey?.get(key) ?? Number.NEGATIVE_INFINITY;
		if (Number.isFinite(last) && input.nowSec - last < intervalSec) continue;
		out.push({
			key,
			paneId: typeof entry.pane_id === "string" && entry.pane_id.trim() ? entry.pane_id.trim() : `entry:${entry.id}`,
			hash: monitorHash(key, input.nowSec, intervalSec),
			entryId: entry.id,
			domainKey: domain.key,
			pr,
			details: {
				domain_key: domain.key,
				entry_id: entry.id,
				event_type: MERGE_PERMISSION_MONITOR_REASON,
				interval_sec: intervalSec,
				pr,
				scheduled: true,
			},
		});
	}
	return out;
}

export function collectMergePermissionWakeCandidatesFromFile(input: {
	statePath: string | null;
	nowSec: number;
	intervalSec?: number;
	lastWakeByKey?: Map<string, number>;
	warn?: (message: string) => void;
}): MergePermissionWakeCandidate[] {
	if (!input.statePath || !existsSync(input.statePath)) return [];
	let state: FlightdeckStateLike;
	try {
		state = JSON.parse(readFileSync(input.statePath, "utf8")) as FlightdeckStateLike;
	} catch (error) {
		input.warn?.(`merge-permission monitor state read failed: ${(error as Error)?.message ?? String(error)}`);
		return [];
	}
	return collectMergePermissionWakeCandidates({
		state,
		nowSec: input.nowSec,
		intervalSec: input.intervalSec,
		lastWakeByKey: input.lastWakeByKey,
		warn: input.warn,
	});
}
