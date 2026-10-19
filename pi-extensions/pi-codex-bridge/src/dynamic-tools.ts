import { createHash } from "node:crypto";
import type { Tool } from "@earendil-works/pi-ai";

const TOOL_NAME_LIMIT = 64;

/** A Codex `DynamicToolSpec` of type `function`. */
export interface DynamicTool {
	type: "function";
	name: string;
	description: string;
	inputSchema: unknown;
}

export interface DynamicToolCatalog {
	declarations: DynamicTool[];
	piNameByCodexName: Map<string, string>;
	/** Identifies the declared set. Codex keeps a thread's start-time tools
	 * and takes no new ones on resume, so a thread serves only this set. */
	signature: string;
}

function baseName(name: string): string {
	const normalized = name.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, TOOL_NAME_LIMIT);
	return normalized.length > 0 ? normalized : "pi_tool";
}

export function buildDynamicTools(tools: Tool[]): DynamicToolCatalog {
	const declarations: DynamicTool[] = [];
	const piNameByCodexName = new Map<string, string>();
	for (const tool of tools) {
		const stem = baseName(tool.name);
		let name = stem;
		let suffix = 2;
		while (piNameByCodexName.has(name)) {
			const tail = `_${suffix++}`;
			name = `${stem.slice(0, TOOL_NAME_LIMIT - tail.length)}${tail}`;
		}
		piNameByCodexName.set(name, tool.name);
		declarations.push({ type: "function", name, description: tool.description, inputSchema: tool.parameters });
	}
	const signature = createHash("sha256").update(JSON.stringify(declarations)).digest("hex").slice(0, 16);
	return { declarations, piNameByCodexName, signature };
}
