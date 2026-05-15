import { sortDashboardItems } from "../dashboard.js";
import { completionBodyWithoutPromptEcho } from "../format.js";
import { taskNumberById } from "../task-records.js";
import type {
	ChatMessage,
	CompletionMessageProvenance,
	PaneTaskRecord,
	PaneTaskRegistry,
	SubagentDashboardItem,
} from "../types.js";

export function activeDashboardItems(items: SubagentDashboardItem[]): SubagentDashboardItem[] {
	return sortDashboardItems(items);
}

// Multiple bg launches of the same agent name produce distinct dashboard rows
// (keyed by taskId). Disambiguate the rendered label with a 1-based occurrence
// suffix in start-time order: "reviewer-arch", "reviewer-arch 2", ... Pane
// agents collapse to a single row per name so they never collide here.
export function dashboardDisplayLabels(items: SubagentDashboardItem[], persistentTaskNumbers?: Map<string, number>): Map<string, string> {
	// Numbering source order:
	//   1. persistent taskNumberById (from tasks.json) when supplied. This is
	//      the canonical per-agent #N the Monitor tab and Detail header use,
	//      so a task reads identically across task-centric surfaces (mini
	//      widget, active-list, Detail header, Chat attribution).
	//   2. In-memory occurrence counter as a fallback for items dispatched
	//      in this turn that haven't been persisted yet, AND so callers
	//      that can't cheaply load the registry still get stable labels.
	const occurrence = new Map<string, number>();
	const total = new Map<string, number>();
	for (const item of items) total.set(item.agent, (total.get(item.agent) ?? 0) + 1);
	const sorted = [...items].sort((a, b) => {
		const aKey = a.startedAt ?? a.taskId;
		const bKey = b.startedAt ?? b.taskId;
		if (aKey === bKey) return 0;
		return aKey < bKey ? -1 : 1;
	});
	const labels = new Map<string, string>();
	for (const item of sorted) {
		const next = (occurrence.get(item.agent) ?? 0) + 1;
		occurrence.set(item.agent, next);
		const persistentN = persistentTaskNumbers?.get(item.taskId);
		// Persistent numbers are session-scoped, so two bg one-shot tasks for the
		// same agent both land on session-local `1`. Fall through to the
		// in-memory occurrence counter unless the persistent number actually
		// disambiguates (`> 1`). `#1` is always suppressed.
		const n = persistentN !== undefined && persistentN > 1 ? persistentN : next;
		const showNumber = (total.get(item.agent) ?? 1) > 1 && n > 1;
		const label = showNumber ? `${item.agent} #${n}` : item.agent;
		labels.set(item.taskId, label);
	}
	return labels;
}

function completionBodyFromRecord(record: PaneTaskRecord | undefined, fallback: string | undefined, task: string | undefined, fallbackProvenance: CompletionMessageProvenance = "fallback"): string {
	if (record?.summary?.trim()) return completionBodyWithoutPromptEcho(record.summary, record.task ?? task, "persisted");
	return completionBodyWithoutPromptEcho(fallback, record?.task ?? task, fallbackProvenance);
}

export function appendBgChatMessages(messages: ChatMessage[], items: SubagentDashboardItem[], taskRegistry: PaneTaskRegistry = {}): void {
	// Bg/oneshot agents skip the file bus (no inbox/outbox/.md/.json), so the
	// file-based scan never sees them. Synthesize delegation+completion records
	// from the dashboard item itself; the data we need is already on it.
	// Use the persistent task registry's #N so chat row attribution matches
	// the Monitor tab and Detail header (not the in-memory counter).
	const persistentTaskNumbers = taskNumberById(Object.values(taskRegistry));
	const labels = dashboardDisplayLabels(items, persistentTaskNumbers);
	for (const item of items) {
		if (item.kind !== "oneshot") continue;
		const label = labels.get(item.taskId) ?? item.agent;
		const startTs = item.startedAt ? Date.parse(item.startedAt) : Number.NaN;
		if (Number.isFinite(startTs) && item.task) {
			messages.push({
				timestamp: startTs,
				agent: item.agent,
				taskId: item.taskId,
				kind: "delegation",
				from: "@orch",
				to: `@${label}`,
				body: item.task,
			});
		}
		const isTerminal = item.status === "completed" || item.status === "failed" || item.status === "blocked" || item.status === "needs_completion";
		if (!isTerminal) continue;
		const endTs = item.completedAt ? Date.parse(item.completedAt) : item.updatedAt ? Date.parse(item.updatedAt) : Number.NaN;
		if (!Number.isFinite(endTs)) continue;
		messages.push({
			timestamp: endTs,
			agent: item.agent,
			taskId: item.taskId,
			kind: "completion",
			from: `@${label}`,
			to: "@orch",
			body: completionBodyFromRecord(taskRegistry[item.taskId], item.message, item.task, item.messageProvenance ?? "task-echo-fallback"),
			status: item.status,
		});
	}
}
