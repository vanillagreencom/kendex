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

export function summarizeMissingToolNames(missing: MissingToolResult[]): Array<{ name: string; count: number }> {
	const counts = new Map<string, number>();
	for (const item of missing) counts.set(item.toolName, (counts.get(item.toolName) ?? 0) + 1);
	return [...counts.entries()]
		.sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
		.map(([name, count]) => ({ name, count }));
}
