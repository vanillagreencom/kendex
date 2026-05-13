import type { AgentConfig, AgentScope } from "./agents.js";
import { createOneShotSessionKey } from "./sessions.js";

export interface DispatchItem {
	agent: string;
	cwd?: string;
	sessionKey?: string;
	task?: string;
}

export interface AgentInventory {
	allowed: AgentConfig[];
	project: AgentConfig[];
	user: AgentConfig[];
}

export interface InventoryValidationResult {
	available: {
		allowed: string[];
		project: string[];
		user: string[];
	};
	missing: string[];
	scope: AgentScope;
}

export function assignEphemeralSessionKeys<T extends DispatchItem>(items: readonly T[]): Array<T & { sessionKey: string }> {
	return items.map((item) => {
		if (item.sessionKey?.trim()) return { ...item, sessionKey: item.sessionKey.trim() };
		return { ...item, sessionKey: createOneShotSessionKey() };
	});
}

export async function mapInBatchesWithConcurrencyLimit<TIn, TOut>(
	items: readonly TIn[],
	batchSize: number,
	concurrency: number,
	fn: (item: TIn, index: number) => Promise<TOut>,
): Promise<TOut[]> {
	if (items.length === 0) return [];
	const normalizedBatchSize = Math.max(1, Math.floor(batchSize));
	const normalizedConcurrency = Math.max(1, Math.floor(concurrency));
	const results: TOut[] = new Array(items.length);
	for (let start = 0; start < items.length; start += normalizedBatchSize) {
		const batch = items.slice(start, start + normalizedBatchSize);
		let nextIndex = 0;
		const workerCount = Math.min(normalizedConcurrency, batch.length);
		const workers = new Array(workerCount).fill(null).map(async () => {
			while (true) {
				const batchIndex = nextIndex++;
				if (batchIndex >= batch.length) return;
				const absoluteIndex = start + batchIndex;
				results[absoluteIndex] = await fn(batch[batchIndex], absoluteIndex);
			}
		});
		await Promise.all(workers);
	}
	return results;
}

export function validateAgentInventory(
	requestedNames: Iterable<string>,
	inventory: AgentInventory,
	scope: AgentScope,
): InventoryValidationResult | undefined {
	const allowed = new Set(inventory.allowed.map((agent) => agent.name));
	const missing = [...new Set(Array.from(requestedNames).filter((name) => !allowed.has(name)))].sort((a, b) => a.localeCompare(b));
	if (missing.length === 0) return undefined;
	return {
		available: {
			allowed: [...allowed].sort((a, b) => a.localeCompare(b)),
			project: inventory.project.map((agent) => agent.name).sort((a, b) => a.localeCompare(b)),
			user: inventory.user.map((agent) => agent.name).sort((a, b) => a.localeCompare(b)),
		},
		missing,
		scope,
	};
}

export function formatInventoryValidationError(validation: InventoryValidationResult): string {
	const availableAllowed = validation.available.allowed.length > 0 ? validation.available.allowed.join(", ") : "none";
	const availableProject = validation.available.project.length > 0 ? validation.available.project.join(", ") : "none";
	const availableUser = validation.available.user.length > 0 ? validation.available.user.join(", ") : "none";
	return [
		`Unknown subagent(s) for agentScope=${validation.scope}: ${validation.missing.join(", ")}.`,
		`Available in selected scope: ${availableAllowed}.`,
		`Project agents: ${availableProject}.`,
		`User agents: ${availableUser}.`,
	].join("\n");
}
