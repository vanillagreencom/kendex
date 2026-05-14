import type { AgentToolResult, ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { AgentConfig, AgentScope } from "./agents.js";
import { getFinalOutput, oneLinePreview } from "./format.js";
import { runPersistentPaneAgent } from "./pane.js";
import {
	cloneMessagesForDetails,
	detailsWithTruncation,
	prepareSingleResultForReturn,
	runSingleAgent,
	truncateForDetails,
	type OnUpdateCallback,
} from "./runner.js";
import { createOneShotSessionKey } from "./sessions.js";
import { settingNumber } from "./settings.js";
import {
	DEFAULT_RESULT_MAX_BYTES,
	DEFAULT_RESULT_MAX_LINES,
	MAX_CONCURRENCY,
	MAX_PARALLEL_TASKS,
	type SingleResult,
	type SubagentDashboardItem,
	type SubagentDetails,
} from "./types.js";

export interface DispatchItem {
	agent: string;
	cwd?: string;
	sessionKey?: string;
	task?: string;
}

export interface DispatchTask extends DispatchItem {
	task: string;
}

type ToolTextResult = {
	content: Array<{ type: "text"; text: string }>;
	details: SubagentDetails;
	isError?: boolean;
};

interface DispatchFlowContext {
	agents: AgentConfig[];
	cwd: string;
	forceSpawn?: boolean;
	makeDetails: (mode: "single" | "parallel" | "chain") => (results: SingleResult[]) => SubagentDetails;
	onUpdate?: OnUpdateCallback;
	parentModel?: string;
	parentSessionId: string;
	parentThinkingLevel?: string;
	pi: ExtensionAPI;
	removeDashboardAgent: (agentName: string) => void;
	resumeSession?: string;
	runtimeRoot: string;
	signal?: AbortSignal;
	updateDashboard: (item: SubagentDashboardItem) => void;
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

export async function runChainDispatch(
	flow: DispatchFlowContext & { chain: DispatchTask[] },
): Promise<ToolTextResult> {
	const chainSteps = assignEphemeralSessionKeys(flow.chain);
	const results: SingleResult[] = [];
	let previousOutput = "";

	for (let i = 0; i < chainSteps.length; i++) {
		const step = chainSteps[i];
		const taskWithContext = step.task.replace(/\{previous\}/g, previousOutput);

		const chainUpdate: OnUpdateCallback | undefined = flow.onUpdate
			? (partial: AgentToolResult<SubagentDetails>) => {
					const currentResult = partial.details?.results[0];
					if (currentResult) {
						const allResults = [...results, currentResult].map((result) => {
							const rawOutput = getFinalOutput(result.messages);
							return {
								...result,
								messages: cloneMessagesForDetails(
									result.messages,
									rawOutput ? truncateForDetails(rawOutput, flow.cwd) : undefined,
									flow.cwd,
								),
							};
						});
						flow.onUpdate?.({
							content: partial.content,
							details: flow.makeDetails("chain")(allResults),
						});
					}
				}
			: undefined;

		const stepAgent = flow.agents.find((agent) => agent.name === step.agent);
		const result = stepAgent?.pane
			? await runPersistentPaneAgent(
					flow.cwd,
					flow.runtimeRoot,
					flow.parentSessionId,
					flow.agents,
					step.agent,
					taskWithContext,
					step.cwd,
					flow.parentModel,
					flow.parentThinkingLevel,
					i + 1,
					flow.pi,
					flow.forceSpawn ?? false,
					flow.resumeSession,
					flow.removeDashboardAgent,
				)
			: await runSingleAgent(
					flow.cwd,
					flow.runtimeRoot,
					flow.agents,
					step.agent,
					taskWithContext,
					step.cwd,
					flow.parentModel,
					flow.parentThinkingLevel,
					i + 1,
					flow.pi,
					flow.signal,
					chainUpdate,
					flow.makeDetails("chain"),
					step.sessionKey,
				);
		results.push(result);
		if (!stepAgent?.pane) {
			flow.updateDashboard({
				agent: result.agent,
				kind: "oneshot",
				message: oneLinePreview(getFinalOutput(result.messages), 120) || result.task,
				model: result.model,
				status: result.exitCode === 0 ? "completed" : "failed",
				task: result.task,
				taskId: result.taskId ?? `${result.agent}-step-${i + 1}`,
				transcriptPath: result.transcriptPath,
				updatedAt: new Date().toISOString(),
				usage: result.usage,
			});
		}

		const isError = result.exitCode !== 0 || result.stopReason === "error" || result.stopReason === "aborted";
		if (isError) {
			const errorMsg = result.errorMessage || result.stderr || getFinalOutput(result.messages) || "(no output)";
			const preparedResults = await Promise.all(
				results.map((candidate, index) =>
					prepareSingleResultForReturn(
						candidate,
						flow.runtimeRoot,
						flow.cwd,
						`chain-step-${candidate.step ?? index + 1}`,
						candidate === result ? errorMsg : undefined,
					),
				),
			);
			const failed = preparedResults[preparedResults.length - 1];
			failed.result.errorMessage = failed.text || errorMsg;
			const details = flow.makeDetails("chain")(preparedResults.map((prepared) => prepared.result));
			return {
				content: [{ type: "text", text: `Chain stopped at step ${i + 1} (${step.agent}): ${failed.text || "(no output)"}` }],
				details: detailsWithTruncation(details, failed),
				isError: true,
			};
		}
		previousOutput = getFinalOutput(result.messages);
	}
	const preparedResults = await Promise.all(
		results.map((result, index) =>
			prepareSingleResultForReturn(result, flow.runtimeRoot, flow.cwd, `chain-step-${result.step ?? index + 1}`),
		),
	);
	const last = preparedResults[preparedResults.length - 1];
	const details = flow.makeDetails("chain")(preparedResults.map((prepared) => prepared.result));
	return {
		content: [{ type: "text", text: last.text || "(no output)" }],
		details: detailsWithTruncation(details, last),
	};
}

export async function runParallelDispatch(
	flow: DispatchFlowContext & { tasks: DispatchTask[] },
): Promise<ToolTextResult> {
	const parallelTasks = assignEphemeralSessionKeys(flow.tasks);
	const parallelBatchSize = Math.max(1, Math.floor(settingNumber("maxParallelTasks", MAX_PARALLEL_TASKS, flow.cwd)));

	const allResults: SingleResult[] = new Array(flow.tasks.length);
	for (let i = 0; i < flow.tasks.length; i++) {
		allResults[i] = {
			agent: parallelTasks[i].agent,
			agentSource: "unknown",
			task: parallelTasks[i].task,
			exitCode: -1,
			messages: [],
			stderr: "",
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
		};
	}

	const emitParallelUpdate = () => {
		if (flow.onUpdate) {
			const running = allResults.filter((r) => r.exitCode === -1).length;
			const done = allResults.filter((r) => r.exitCode !== -1).length;
			const updateResults = allResults.map((result) => {
				const rawOutput = getFinalOutput(result.messages);
				return {
					...result,
					messages: cloneMessagesForDetails(
						result.messages,
						rawOutput ? truncateForDetails(rawOutput, flow.cwd) : undefined,
						flow.cwd,
					),
				};
			});
			flow.onUpdate({
				content: [{ type: "text", text: `Parallel: ${done}/${allResults.length} done, ${running} running...` }],
				details: flow.makeDetails("parallel")(updateResults),
			});
		}
	};

	const maxConcurrency = Math.max(1, Math.floor(settingNumber("maxConcurrency", MAX_CONCURRENCY, flow.cwd)));
	const results = await mapInBatchesWithConcurrencyLimit(parallelTasks, parallelBatchSize, maxConcurrency, async (t, index) => {
		const updateOneshotDashboard = (item: SingleResult) => {
			flow.updateDashboard({
				agent: item.agent,
				kind: "oneshot",
				message: oneLinePreview(getFinalOutput(item.messages), 120) || item.task,
				model: item.model,
				status: item.exitCode === -1 ? "running" : item.exitCode === 0 ? "completed" : "failed",
				task: item.task,
				taskId: item.taskId ?? `${item.agent}-${index}`,
				transcriptPath: item.transcriptPath,
				updatedAt: new Date().toISOString(),
				usage: item.usage,
			});
		};
		const taskAgent = flow.agents.find((agent) => agent.name === t.agent);
		const result = taskAgent?.pane
			? await runPersistentPaneAgent(
					flow.cwd,
					flow.runtimeRoot,
					flow.parentSessionId,
					flow.agents,
					t.agent,
					t.task,
					t.cwd,
					flow.parentModel,
					flow.parentThinkingLevel,
					undefined,
					flow.pi,
					flow.forceSpawn ?? false,
					flow.resumeSession,
					flow.removeDashboardAgent,
				)
			: await runSingleAgent(
					flow.cwd,
					flow.runtimeRoot,
					flow.agents,
					t.agent,
					t.task,
					t.cwd,
					flow.parentModel,
					flow.parentThinkingLevel,
					undefined,
					flow.pi,
					flow.signal,
					(partial) => {
						if (partial.details?.results[0]) {
							allResults[index] = partial.details.results[0];
							updateOneshotDashboard(partial.details.results[0]);
							emitParallelUpdate();
						}
					},
					flow.makeDetails("parallel"),
					t.sessionKey,
				);
		allResults[index] = result;
		if (!taskAgent?.pane) updateOneshotDashboard(result);
		emitParallelUpdate();
		return result;
	});

	const successCount = results.filter((r) => r.exitCode === 0).length;
	const perResultLimits = (() => {
		const total = { maxBytes: Math.max(1, Math.floor(settingNumber("resultMaxBytes", DEFAULT_RESULT_MAX_BYTES, flow.cwd))), maxLines: Math.max(1, Math.floor(settingNumber("resultMaxLines", DEFAULT_RESULT_MAX_LINES, flow.cwd))) };
		const count = Math.max(1, results.length);
		return { maxBytes: Math.max(1024, Math.floor(total.maxBytes / count)), maxLines: Math.max(40, Math.floor(total.maxLines / count)) };
	})();
	const preparedResults = await Promise.all(
		results.map((result, index) =>
			prepareSingleResultForReturn(
				result,
				flow.runtimeRoot,
				flow.cwd,
				`parallel-${index + 1}-${result.agent}`,
				undefined,
				perResultLimits,
			),
		),
	);
	const sections = preparedResults.map((prepared) => {
		const r = prepared.result;
		const status = r.exitCode === 0 ? "completed" : r.exitCode === -1 ? "running" : "failed";
		return `## ${r.agent} (${status})\n${prepared.text || "(no output)"}`;
	});
	return {
		content: [{ type: "text", text: `Parallel: ${successCount}/${results.length} succeeded\n\n${sections.join("\n\n")}` }],
		details: flow.makeDetails("parallel")(preparedResults.map((prepared) => prepared.result)),
	};
}

export async function runSingleDispatch(
	flow: DispatchFlowContext & { agent: string; task: string; cwdOverride?: string; sessionKey?: string },
): Promise<ToolTextResult> {
	const agent = flow.agents.find((candidate) => candidate.name === flow.agent);
	const result = agent?.pane
		? await runPersistentPaneAgent(
				flow.cwd,
				flow.runtimeRoot,
				flow.parentSessionId,
				flow.agents,
				flow.agent,
				flow.task,
				flow.cwdOverride,
				flow.parentModel,
				flow.parentThinkingLevel,
				undefined,
				flow.pi,
				flow.forceSpawn ?? false,
				flow.resumeSession,
				flow.removeDashboardAgent,
			)
		: await runSingleAgent(
				flow.cwd,
				flow.runtimeRoot,
				flow.agents,
				flow.agent,
				flow.task,
				flow.cwdOverride,
				flow.parentModel,
				flow.parentThinkingLevel,
				undefined,
				flow.pi,
				flow.signal,
				flow.onUpdate,
				flow.makeDetails("single"),
				flow.sessionKey,
			);
	if (!agent?.pane) {
		flow.updateDashboard({
			agent: result.agent,
			kind: "oneshot",
			message: oneLinePreview(getFinalOutput(result.messages), 120) || result.task,
			model: result.model,
			status: result.exitCode === 0 ? "completed" : "failed",
			task: result.task,
			taskId: result.taskId ?? result.agent,
			transcriptPath: result.transcriptPath,
			updatedAt: new Date().toISOString(),
			usage: result.usage,
		});
	}
	const isError = result.exitCode !== 0 || result.stopReason === "error" || result.stopReason === "aborted";
	if (isError) {
		const errorMsg = result.errorMessage || result.stderr || getFinalOutput(result.messages) || "(no output)";
		const prepared = await prepareSingleResultForReturn(result, flow.runtimeRoot, flow.cwd, "single-error", errorMsg);
		prepared.result.errorMessage = prepared.text || errorMsg;
		const details = flow.makeDetails("single")([prepared.result]);
		return {
			content: [{ type: "text", text: `Agent ${result.stopReason || "failed"}: ${prepared.text || "(no output)"}` }],
			details: detailsWithTruncation(details, prepared),
			isError: true,
		};
	}
	const prepared = await prepareSingleResultForReturn(result, flow.runtimeRoot, flow.cwd, "single");
	const details = flow.makeDetails("single")([prepared.result]);
	return {
		content: [{ type: "text", text: prepared.text || "(no output)" }],
		details: detailsWithTruncation(details, prepared),
	};
}
