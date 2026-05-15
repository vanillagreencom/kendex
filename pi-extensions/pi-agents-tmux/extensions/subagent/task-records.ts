import * as fs from "node:fs";
import { taskRegistryPath } from "./paths.js";
import type { PaneTaskRecord, PaneTaskRegistry, PaneTaskStatus, UsageStats } from "./types.js";

export type MonitorSessionType = "pane" | "bg-lane" | "bg-one-shot";

export function recordTimestampLocal(record: PaneTaskRecord): number {
	const value = Date.parse(record.completedAt ?? record.createdAt ?? "");
	return Number.isFinite(value) ? value : 0;
}

export function recordLatestTimestamp(record: PaneTaskRecord): number {
	const value = Date.parse(record.completedAt ?? record.updatedAt ?? record.createdAt ?? "");
	return Number.isFinite(value) ? value : 0;
}

export function recordMonitorKind(record: PaneTaskRecord): "pane" | "oneshot" {
	if (record.kind === "pane" || record.kind === "oneshot") return record.kind;
	if (record.paneId || record.inboxFile || record.processingFile || record.doneFile || record.outboxFile || record.completionSourcePath || record.completionArchivePath) return "pane";
	return "oneshot";
}

export function monitorStatusIsActive(status: PaneTaskStatus | string | undefined): boolean {
	return !monitorStatusIsTerminal(status);
}

export function monitorStatusIsTerminal(status: PaneTaskStatus | string | undefined): boolean {
	return status === "completed" || status === "failed" || status === "blocked" || status === "needs_completion" || status === "cancelled";
}

export function monitorSessionKey(record: PaneTaskRecord): { id: string; type: MonitorSessionType } {
	const kind = recordMonitorKind(record);
	if (kind === "pane") {
		if (record.paneId?.trim()) return { id: `pane:${record.paneId.trim()}`, type: "pane" };
		if (record.transcriptPath?.trim()) return { id: `pane-transcript:${record.transcriptPath.trim()}`, type: "pane" };
		return { id: `pane-task:${record.taskId}`, type: "pane" };
	}
	if (record.sessionKey?.trim()) return { id: `bg-lane:${record.agent}:${record.sessionKey.trim()}`, type: "bg-lane" };
	return { id: `bg-one-shot:${record.taskId}`, type: "bg-one-shot" };
}

export function usageSum(records: PaneTaskRecord[]): UsageStats | undefined {
	const total: UsageStats = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 };
	let seen = false;
	for (const usage of records.map((record) => record.usage).filter(Boolean) as UsageStats[]) {
		seen = true;
		total.input += usage.input || 0;
		total.output += usage.output || 0;
		total.cacheRead += usage.cacheRead || 0;
		total.cacheWrite += usage.cacheWrite || 0;
		total.cost += usage.cost || 0;
		total.contextTokens += usage.contextTokens || 0;
		total.turns += usage.turns || 0;
	}
	return seen ? total : undefined;
}

export function sortedMonitorRecords(registry: PaneTaskRegistry): PaneTaskRecord[] {
	return Object.values(registry)
		.filter((record) => record.taskId && record.agent)
		.sort((a, b) => recordTimestampLocal(b) - recordTimestampLocal(a));
}

export function taskNumberById(records: PaneTaskRecord[]): Map<string, number> {
	const bySession = new Map<string, PaneTaskRecord[]>();
	for (const record of records) {
		if (!record.taskId || !record.agent) continue;
		const sessionId = monitorSessionKey(record).id;
		const list = bySession.get(sessionId) ?? [];
		list.push(record);
		bySession.set(sessionId, list);
	}
	const out = new Map<string, number>();
	for (const list of bySession.values()) {
		list
			.sort((a, b) => {
				const delta = recordTimestampLocal(a) - recordTimestampLocal(b);
				return delta !== 0 ? delta : a.taskId.localeCompare(b.taskId);
			})
			.forEach((record, index) => out.set(record.taskId, index + 1));
	}
	return out;
}

function normalizeTaskRegistryShape(parsed: unknown): PaneTaskRegistry {
	if (Array.isArray(parsed)) return Object.fromEntries(parsed.filter((record) => record?.taskId).map((record) => [record.taskId, record])) as PaneTaskRegistry;
	return parsed && typeof parsed === "object" ? parsed as PaneTaskRegistry : {};
}

export function loadTaskRegistrySync(runtimeRoot: string): PaneTaskRegistry {
	try {
		return normalizeTaskRegistryShape(JSON.parse(fs.readFileSync(taskRegistryPath(runtimeRoot), "utf-8")));
	} catch {
		return {};
	}
}
