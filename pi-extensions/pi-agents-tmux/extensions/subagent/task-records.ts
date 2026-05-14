import * as fs from "node:fs";
import { taskRegistryPath } from "./paths.js";
import {
	type PaneTaskRecord,
	type PaneTaskRegistry,
} from "./types.js";

function recordCreatedTimestamp(record: PaneTaskRecord): number {
	const value = Date.parse(record.createdAt ?? "");
	return Number.isFinite(value) ? value : 0;
}

export function taskNumberById(records: PaneTaskRecord[]): Map<string, number> {
	const byAgent = new Map<string, PaneTaskRecord[]>();
	for (const record of records) {
		if (!record.taskId || !record.agent) continue;
		const list = byAgent.get(record.agent) ?? [];
		list.push(record);
		byAgent.set(record.agent, list);
	}
	const out = new Map<string, number>();
	for (const list of byAgent.values()) {
		list
			.sort((a, b) => {
				const delta = recordCreatedTimestamp(a) - recordCreatedTimestamp(b);
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
