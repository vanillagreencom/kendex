// Detect missing assistant tool_use ↔ user tool_result pairs before cc-session-io
// repairs them with synthetic "[no tool result recorded]" blocks.
// Kept pure so tests can exercise the exact audit without activating Pi.

export interface MissingToolResult {
	id: string;
	toolName: string;
	assistantIndex: number;
	userIndex: number | null;
}

function contentBlocks(content: unknown): Array<Record<string, any>> {
	return Array.isArray(content) ? content.filter((block): block is Record<string, any> => Boolean(block && typeof block === "object")) : [];
}

function toolUses(content: unknown): Array<{ id: string; name: string }> {
	return contentBlocks(content)
		.filter((block) => block.type === "tool_use" && typeof block.id === "string")
		.map((block) => ({ id: block.id, name: typeof block.name === "string" && block.name ? block.name : "unknown" }));
}

function toolResultIds(content: unknown): Set<string> {
	const ids = new Set<string>();
	for (const block of contentBlocks(content)) {
		if (block.type === "tool_result" && typeof block.tool_use_id === "string") ids.add(block.tool_use_id);
	}
	return ids;
}

/**
 * Anthropic history requires an assistant message containing tool_use blocks to
 * be followed by a user message containing matching tool_result blocks. Return
 * every tool_use that would force repairToolPairing to synthesize a result.
 */
export function findUnpairedToolUses(messages: Array<{ role?: string; content?: unknown }>): MissingToolResult[] {
	const missing: MissingToolResult[] = [];
	for (let i = 0; i < messages.length; i++) {
		const msg = messages[i];
		if (msg?.role !== "assistant") continue;
		const uses = toolUses(msg.content);
		if (uses.length === 0) continue;

		const next = messages[i + 1];
		const nextUserIndex = next?.role === "user" ? i + 1 : null;
		const resultIds = nextUserIndex == null ? new Set<string>() : toolResultIds(next.content);
		for (const use of uses) {
			if (!resultIds.has(use.id)) {
				missing.push({ id: use.id, toolName: use.name, assistantIndex: i, userIndex: nextUserIndex });
			}
		}
	}
	return missing;
}

export const LOST_TOOL_RESULT_TEXT =
	"Claude bridge: the result of this tool call was lost before the session was rebuilt "
	+ "(the turn was interrupted). Treat the call as failed — it may or may not have executed. "
	+ "Re-run the tool if its output is still needed.";

/**
 * Insert explicit, bridge-authored error results for every unpaired tool_use,
 * IN PLACE, before cc-session-io's repairToolPairing runs.
 *
 * repairToolPairing backfills with a bare "[no tool result recorded]" — a
 * placeholder the model reads as tool OUTPUT and keeps reasoning on (observed:
 * two bash calls in the 2026-07-28 token test, silently treated as if they had
 * returned). An is_error result that says what happened and what to do turns a
 * silent correctness hazard into a recoverable failure.
 *
 * Results are prepended to the immediately following user message (tool_result
 * blocks must lead a user message), or a new user message is inserted when none
 * follows. `missing` must come from findUnpairedToolUses on the same array.
 */
export function insertLostToolResultPlaceholders(
	messages: Array<{ role?: string; content?: unknown }>,
	missing: MissingToolResult[],
): void {
	const block = (id: string) => ({ type: "tool_result", tool_use_id: id, content: LOST_TOOL_RESULT_TEXT, is_error: true });
	const byAssistant = new Map<number, MissingToolResult[]>();
	for (const item of missing) {
		const group = byAssistant.get(item.assistantIndex) ?? [];
		group.push(item);
		byAssistant.set(item.assistantIndex, group);
	}
	// Descending order so inserting a new user message never shifts an index a
	// later (earlier-in-array) group still needs.
	for (const assistantIndex of [...byAssistant.keys()].sort((a, b) => b - a)) {
		const group = byAssistant.get(assistantIndex)!;
		const blocks = group.map((item) => block(item.id));
		const userIndex = group[0].userIndex;
		if (userIndex != null && messages[userIndex]?.role === "user") {
			const user = messages[userIndex] as { role: string; content: unknown };
			const existing = typeof user.content === "string"
				? (user.content ? [{ type: "text", text: user.content }] : [])
				: Array.isArray(user.content) ? user.content : [];
			user.content = [...blocks, ...existing];
		} else {
			messages.splice(assistantIndex + 1, 0, { role: "user", content: blocks });
		}
	}
}

export function summarizeMissingToolNames(missing: MissingToolResult[]): Array<{ name: string; count: number }> {
	const counts = new Map<string, number>();
	for (const item of missing) counts.set(item.toolName, (counts.get(item.toolName) ?? 0) + 1);
	return [...counts.entries()]
		.sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
		.map(([name, count]) => ({ name, count }));
}
