import { isTaskActive, isTaskTurnFinished, normalizePaneTaskStatus } from "./outcomes.js";
import * as fs from "node:fs";
import { fileVersion } from "./file-version.js";
import { taskRegistryPath } from "./paths.js";
import type { PaneTaskRecord, PaneTaskRegistry, PaneTaskStatus, SubagentDashboardItem, SubagentDashboardStatus, UsageStats } from "./types.js";

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
	return isTaskActive(status);
}

export function monitorStatusIsTerminal(status: PaneTaskStatus | string | undefined): boolean {
	return isTaskTurnFinished(status);
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
	const total: UsageStats = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 };
	let seen = false;
	for (const usage of records.map((record) => record.usage).filter(Boolean) as UsageStats[]) {
		seen = true;
		total.input += usage.input || 0;
		total.output += usage.output || 0;
		total.reasoning = (total.reasoning ?? 0) + (usage.reasoning || 0);
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

export function monitorStatusFromDashboard(status: SubagentDashboardStatus): PaneTaskStatus {
	// `waiting` only exists on the dashboard; the registry models that as `queued`.
	return normalizePaneTaskStatus(status);
}

// One live lifecycle fingerprint for the whole dashboard item set. Cheap enough to
// compare on a UI tick, and changes exactly when a monitor row would need to move.
export function liveDashboardSignature(items: SubagentDashboardItem[]): string {
	return items
		.map((item) => `${item.taskId}|${item.status}|${item.updatedAt ?? ""}|${item.completedAt ?? ""}`)
		.sort()
		.join("|");
}

// `tasks.json` is a disk snapshot; `dashboardState.items` is the authoritative
// in-memory lifecycle view the statusline and mini-dashboard render from. Overlay
// live items on the snapshot so all three surfaces agree: live wins on lifecycle
// fields, the snapshot keeps completion detail (summary/files/validation/notes)
// that never reaches a dashboard item, and history records the dashboard has
// dropped stay visible.
export function mergeLiveDashboardItems(registry: PaneTaskRegistry, items: SubagentDashboardItem[]): PaneTaskRegistry {
	if (items.length === 0) return registry;
	const merged: PaneTaskRegistry = { ...registry };
	for (const item of items) {
		if (!item.taskId || !item.agent) continue;
		const record = merged[item.taskId];
		merged[item.taskId] = {
			...record,
			taskId: item.taskId,
			agent: item.agent,
			task: item.task ?? record?.task ?? "",
			status: monitorStatusFromDashboard(item.status),
			kind: item.kind ?? record?.kind,
			paneId: item.paneId ?? record?.paneId,
			sessionKey: item.sessionKey ?? record?.sessionKey,
			sessionMode: item.sessionMode ?? record?.sessionMode,
			transcriptPath: item.transcriptPath ?? record?.transcriptPath,
			deliverAs: item.deliverAs ?? record?.deliverAs,
			usage: item.usage ?? record?.usage,
			model: item.model ?? record?.model,
			effort: item.effort ?? record?.effort,
			createdAt: record?.createdAt ?? item.startedAt ?? item.updatedAt,
			updatedAt: item.updatedAt ?? record?.updatedAt,
			completedAt: item.completedAt ?? record?.completedAt,
		};
	}
	return merged;
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

const EMPTY_TASK_REGISTRY: PaneTaskRegistry = Object.freeze({});

function deepFreeze<T>(value: T): T {
	if (value && typeof value === "object" && !Object.isFrozen(value)) {
		for (const child of Object.values(value)) deepFreeze(child);
		Object.freeze(value);
	}
	return value;
}

/**
 * Keeps the most recently read or written runtime's task registry once per file version (`file-version.ts::fileVersion`:
 * device, inode, byte size and modification time). A read that finds the same version
 * gets the parsed registry it got before, from one stat and no read. That registry is
 * shared by every caller until the version changes, so it is frozen: a caller that
 * needs to change it takes a mutable copy of the retained JSON. Local writers publish
 * that JSON under the writer lock after replacement. A failed read is not cached.
 */
export class TaskRegistryReader {
	private cache: { filePath: string; version: string; content: string; registry: PaneTaskRegistry } | undefined;

	read(runtimeRoot: string): PaneTaskRegistry {
		const filePath = taskRegistryPath(runtimeRoot);
		let version: string;
		try {
			version = fileVersion(fs.statSync(filePath));
		} catch {
			this.clear();
			return EMPTY_TASK_REGISTRY;
		}
		const cached = this.cache;
		if (cached?.filePath === filePath && cached.version === version) return cached.registry;
		let content: string;
		try {
			content = fs.readFileSync(filePath, "utf-8");
		} catch {
			this.clear();
			return EMPTY_TASK_REGISTRY;
		}
		return this.cacheContent(filePath, version, content);
	}

	/** Check the version before copying; nested edits cannot change shared readers. */
	mutableCopy(runtimeRoot: string): PaneTaskRegistry {
		this.read(runtimeRoot);
		return this.cache ? normalizeTaskRegistryShape(JSON.parse(this.cache.content)) : {};
	}

	/** Publish the exact written JSON while the task registry writer still holds its lock. */
	rememberWrite(runtimeRoot: string, content: string): void {
		const filePath = taskRegistryPath(runtimeRoot);
		let version: string;
		try {
			version = fileVersion(fs.statSync(filePath));
		} catch {
			this.clear();
			return;
		}
		this.cacheContent(filePath, version, content);
	}

	private cacheContent(filePath: string, version: string, content: string): PaneTaskRegistry {
		let registry: PaneTaskRegistry;
		try {
			registry = deepFreeze(normalizeTaskRegistryShape(JSON.parse(content)));
		} catch {
			registry = EMPTY_TASK_REGISTRY;
			content = "{}";
		}
		this.cache = { filePath, version, content, registry };
		return registry;
	}

	clear(): void {
		this.cache = undefined;
	}
}

/** Shared by task updates, completion polling and dashboard reads; session teardown clears it. */
export const taskRegistryReader = new TaskRegistryReader();
