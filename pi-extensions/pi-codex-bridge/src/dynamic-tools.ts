import type { Tool } from "@earendil-works/pi-ai";
import type { DynamicTool } from "./protocol.js";

const TOOL_NAME_LIMIT = 64;

function baseName(name: string): string {
	const normalized = name.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, TOOL_NAME_LIMIT);
	return normalized.length > 0 ? normalized : "pi_tool";
}

export interface DynamicToolCatalog {
	declarations: DynamicTool[];
	piNameByCodexName: Map<string, string>;
	signature: string;
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
		declarations.push({
			type: "function",
			name,
			description: tool.description,
			inputSchema: tool.parameters,
		});
	}
	return {
		declarations,
		piNameByCodexName,
		signature: JSON.stringify(declarations),
	};
}
