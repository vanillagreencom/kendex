import { createHash } from "node:crypto";
import type { Tool } from "@earendil-works/pi-ai";
import { PI_TOOL_NAMESPACE } from "./codex-policy.js";

const TOOL_NAME_LIMIT = 64;

/** A Codex `DynamicToolNamespaceTool`: a function inside a namespace. */
export interface DynamicTool {
	type: "function";
	name: string;
	description: string;
	inputSchema: unknown;
}

/** A Codex `DynamicToolSpec` of type `namespace`. */
export interface DynamicToolNamespace {
	type: "namespace";
	name: typeof PI_TOOL_NAMESPACE;
	description: string;
	tools: DynamicTool[];
}

export interface DynamicToolCatalog {
	/** One `pi` namespace holding every Pi tool, or none when Pi has no tools:
	 * Codex refuses an empty namespace. */
	declarations: DynamicToolNamespace[];
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
	const functions: DynamicTool[] = [];
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
		functions.push({ type: "function", name, description: tool.description, inputSchema: tool.parameters });
	}
	const declarations: DynamicToolNamespace[] = functions.length === 0
		? []
		: [{ type: "namespace", name: PI_TOOL_NAMESPACE, description: "Tools of the Pi session this conversation runs in.", tools: functions }];
	const signature = createHash("sha256").update(JSON.stringify(declarations)).digest("hex").slice(0, 16);
	return { declarations, piNameByCodexName, signature };
}
