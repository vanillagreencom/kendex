import type { AgentToolResult, ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { AgentConfig, AgentScope } from "./agents.js";
import { withChildBudget } from "./child-budget.js";
import { COMPLETION_SUMMARY_UNAVAILABLE, getFinalOutput, normalizeSummaryText } from "./format.js";
import { probeTmux, runPersistentPaneAgent } from "./pane.js";
import {
	cloneMessagesForDetails,
	detailsWithTruncation,
	prepareSingleResultForReturn,
	runSingleAgent,
	truncateForDetails,
	type OnUpdateCallback,
} from "./runner.js";
import { createOneShotSessionKey } from "./sessions.js";
import { singleResultIsError, singleResultStatus } from "./outcomes.js";
import { type AgentModelRegistry, resultLimits, settingNumber, splitResultLimits } from "./settings.js";
import { readTaskRegistry } from "./tasks.js";
import {
	MAX_CONCURRENCY,
	type PreparedSingleResult,
	type ResultLimits,
	type SingleResult,
	type SubagentDashboardItem,
	type SubagentDetails,
} from "./types.js";

export interface DispatchItem {
	agent: string;
	cwd?: string;
	sessionKey?: string;
	sameSession?: boolean;
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
	/** Refuse a pane agent where no tmux server answers, instead of running it headless. */
	paneOnly?: boolean;
	parentModel?: string;
	modelRegistry?: AgentModelRegistry;
	parentSessionId: string;
	parentThinkingLevel?: string;
	pi: ExtensionAPI;
	removeDashboardAgent: (agentName: string) => void;
	resumeSession?: string;
	sameSession?: boolean;
	runtimeRoot: string;
	signal?: AbortSignal;
	updateDashboard: (item: SubagentDashboardItem) => void;
}

/** Where one dispatch runs its `pane: true` agents, decided once before any launch. */
type PaneLane = { kind: "pane" } | { kind: "headless"; cause: string };

async function resolvePaneLane(flow: DispatchFlowContext, requested: readonly string[]): Promise<PaneLane> {
	flow.signal?.throwIfAborted();
	if (flow.paneOnly) return { kind: "pane" };
	if (!requested.some((name) => flow.agents.find((agent) => agent.name === name)?.pane)) return { kind: "pane" };
	const reach = await withChildBudget(flow.pi, flow.cwd, flow.signal, probeTmux);
	return reach.kind === "reachable" ? { kind: "pane" } : { kind: "headless", cause: reach.cause };
}

function runsInPane(agent: AgentConfig | undefined, lane: PaneLane): boolean {
	return agent?.pane === true && lane.kind === "pane";
}

/**
 * Reports explicit session keys outside answer truncation, then adds one
 * `pane-fallback reason=no-tmux` line when a
 * pane agent ran headless, and names each such task the way a queued pane
 * task is named, so a caller stores the same `Task ID:` in both modes.
 */
function withPaneFallbackNotice(result: ToolTextResult, lane: PaneLane, agents: AgentConfig[]): ToolTextResult {
	const sessions = result.details.results.flatMap((item, index) => item.sessionKeyExplicit && item.sessionKey ? [`Session: agent=${item.agent}${result.details.mode === "chain" ? ` step=${item.step ?? index + 1}` : result.details.mode === "parallel" ? ` item=${index + 1}` : ""} sessionKey=${item.sessionKey}`] : []);
	if (sessions.length) {
		const [first, ...rest] = result.content;
		result = { ...result, content: [{ type: "text", text: `${sessions.join("\n")}\n\n${first?.text ?? ""}` }, ...rest] };
	}
	if (lane.kind === "pane") return result;
	const fellBack = result.details.results.filter((item) => agents.find((agent) => agent.name === item.agent)?.pane);
	if (fellBack.length === 0) return result;
	const notice = [
		"pane-fallback reason=no-tmux",
		`${lane.cause} Pane agents ran headless as background one-shot processes: ${[...new Set(fellBack.map((item) => item.agent))].join(", ")}.`,
		...fellBack.flatMap((item) => (item.taskId ? [`Task ID: ${item.taskId}`] : [])),
	].join("\n");
	const [first, ...rest] = result.content;
	return { ...result, content: [{ type: "text", text: first ? `${notice}\n\n${first.text}` : notice }, ...rest] };
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

export async function mapWithConcurrencyLimit<TIn, TOut>(
	items: readonly TIn[],
	concurrency: number,
	fn: (item: TIn, index: number) => Promise<TOut>,
	signal?: AbortSignal,
): Promise<TOut[]> {
	if (items.length === 0) return [];
	const limit = Math.max(1, Math.min(Math.floor(concurrency), items.length));
	const results: TOut[] = new Array(items.length);
	let nextIndex = 0;
	const workers = new Array(limit).fill(null).map(async () => {
		while (true) {
			signal?.throwIfAborted();
			const i = nextIndex++;
			if (i >= items.length) return;
			results[i] = await fn(items[i], i);
		}
	});
	await Promise.all(workers);
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

function singleResultNeedsCompletion(result: SingleResult): boolean {
	return singleResultStatus(result) === "needs_completion";
}

function dashboardMessageForOneShotResult(result: SingleResult, persistedSummary?: string): string {
	const status = singleResultStatus(result);
	if (singleResultIsError(result)) return result.errorMessage || result.stderr || getFinalOutput(result.messages) || COMPLETION_SUMMARY_UNAVAILABLE;
	const persisted = normalizeSummaryText(persistedSummary);
	if (persisted) return [result.reuseNotice, persisted].filter(Boolean).join("\n");
	const finalOutput = getFinalOutput(result.messages);
	if (finalOutput.trim()) return [result.reuseNotice, finalOutput].filter(Boolean).join("\n");
	return singleResultStatus(result) === "running" ? result.task : COMPLETION_SUMMARY_UNAVAILABLE;
}

function dashboardMessageProvenanceForOneShotResult(result: SingleResult, persistedSummary?: string): SubagentDashboardItem["messageProvenance"] {
	if (singleResultStatus(result) === "refused" || result.errorMessage || result.stderr) return "diagnostic";
	if (normalizeSummaryText(persistedSummary) || getFinalOutput(result.messages).trim()) return "persisted";
	return singleResultStatus(result) === "running" ? "task-echo-fallback" : "placeholder";
}

async function persistedSummaryForOneShotResult(runtimeRoot: string, result: SingleResult): Promise<string | undefined> {
	if (!result.taskId) return undefined;
	try {
		return (await readTaskRegistry(runtimeRoot))[result.taskId]?.summary;
	} catch {
		return undefined;
	}
}

async function dashboardMessageForCompletedOneShotResult(runtimeRoot: string, result: SingleResult): Promise<string> {
	return dashboardMessageForOneShotResult(result, await persistedSummaryForOneShotResult(runtimeRoot, result));
}

function needsCompletionMessage(result: SingleResult): string {
	const reason = result.needsCompletionReason ? ` (${result.needsCompletionReason})` : "";
	return result.errorMessage || `Agent needs completion${reason}; inspect result details and worker cwd state.`;
}

export function parallelResultLimits(cwd: string, count: number): ResultLimits {
	return splitResultLimits(resultLimits(cwd), count);
}

export function formatPreparedParallelSection(prepared: PreparedSingleResult): string {
	const r = prepared.result;
	const status = singleResultStatus(r);
	const text = singleResultNeedsCompletion(r) ? prepared.text || needsCompletionMessage(r) : singleResultIsError(r) ? prepared.text || "(no output)" : [r.reuseNotice, prepared.text || "(no output)"].filter(Boolean).join("\n");
	const metadata = [
		r.taskId ? `Task: ${r.taskId}` : undefined,
		r.transcriptPath ? `Transcript: ${r.transcriptPath}` : undefined,
		r.fullOutputPath ? `Full output: ${r.fullOutputPath}` : undefined,
		r.fullOutputError ? `Full output preservation failed: ${r.fullOutputError}` : undefined,
		r.truncation ? `Inline output: truncated; full output stored above when available.` : undefined,
	].filter(Boolean).join("\n");
	return `## ${r.agent} (${status})${metadata ? `\n${metadata}` : ""}\n${text}`;
}

export async function runChainDispatch(
	flow: DispatchFlowContext & { chain: DispatchTask[] },
): Promise<ToolTextResult> {
	const lane = await resolvePaneLane(flow, flow.chain.map((step) => step.agent));
	return withPaneFallbackNotice(await chainDispatch(flow, lane), lane, flow.agents);
}

async function chainDispatch(
	flow: DispatchFlowContext & { chain: DispatchTask[] },
	lane: PaneLane,
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
		const result = await withChildBudget(flow.pi, flow.cwd, flow.signal, async () => runsInPane(stepAgent, lane)
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
					flow.modelRegistry,
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
					step.sameSession ?? flow.sameSession,
					flow.modelRegistry,
				));
		results.push(result);
		if (!runsInPane(stepAgent, lane) || singleResultStatus(result) === "refused") {
			flow.updateDashboard({
				reuseNotice: result.reuseNotice,
				agent: result.agent,
				kind: result.kind ?? "oneshot",
				message: await dashboardMessageForCompletedOneShotResult(flow.runtimeRoot, result),
				messageProvenance: dashboardMessageProvenanceForOneShotResult(result, await persistedSummaryForOneShotResult(flow.runtimeRoot, result)),
				model: result.model,
				effort: result.effort,
				sessionMode: result.sessionMode,
				sessionKey: result.sessionKeyExplicit ? result.sessionKey : undefined,
				status: singleResultStatus(result),
				task: result.task,
				taskId: result.taskId ?? `${result.agent}-step-${i + 1}`,
				transcriptPath: result.transcriptPath,
				updatedAt: new Date().toISOString(),
				usage: result.usage,
			});
		}

		if (singleResultNeedsCompletion(result)) {
			const message = needsCompletionMessage(result);
			const preparedResults = await Promise.all(
				results.map((candidate, index) =>
					prepareSingleResultForReturn(
						candidate,
						flow.runtimeRoot,
						flow.cwd,
						`chain-step-${candidate.step ?? index + 1}`,
						candidate === result ? message : undefined,
					),
				),
			);
			const blocked = preparedResults[preparedResults.length - 1];
			const details = flow.makeDetails("chain")(preparedResults.map((prepared) => prepared.result));
			return {
				content: [{ type: "text", text: `Chain stopped at step ${i + 1} (${step.agent} needs completion): ${blocked.text || message}` }],
				details: detailsWithTruncation(details, blocked),
			};
		}

		const isError = singleResultIsError(result);
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
		content: [{ type: "text", text: [...results.map((result) => result.reuseNotice).filter(Boolean), last.text || "(no output)"].join("\n") }],
		details: detailsWithTruncation(details, last),
	};
}

export async function runParallelDispatch(
	flow: DispatchFlowContext & { tasks: DispatchTask[] },
): Promise<ToolTextResult> {
	const lane = await resolvePaneLane(flow, flow.tasks.map((task) => task.agent));
	return withPaneFallbackNotice(await parallelDispatch(flow, lane), lane, flow.agents);
}

async function parallelDispatch(
	flow: DispatchFlowContext & { tasks: DispatchTask[] },
	lane: PaneLane,
): Promise<ToolTextResult> {
	const parallelTasks = assignEphemeralSessionKeys(flow.tasks);

	const allResults: SingleResult[] = new Array(flow.tasks.length);
	for (let i = 0; i < flow.tasks.length; i++) {
		allResults[i] = {
			agent: parallelTasks[i].agent,
			agentSource: "unknown",
			task: parallelTasks[i].task,
			// Lane is known from frontmatter before the worker starts, so in-flight
			// rows carry the right badge instead of defaulting to bg.
			kind: runsInPane(flow.agents.find((agent) => agent.name === parallelTasks[i].agent), lane) ? "pane" : "oneshot",
			exitCode: -1,
			messages: [],
			stderr: "",
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
		};
	}

	const emitParallelUpdate = () => {
		if (flow.onUpdate) {
			const running = allResults.filter((r) => singleResultStatus(r) === "running").length;
			const done = allResults.length - running;
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
	const results = await mapWithConcurrencyLimit(parallelTasks, maxConcurrency, async (t, index) => {
		const updateOneshotDashboard = async (item: SingleResult, usePersistedSummary = false) => {
			const persistedSummary = usePersistedSummary ? await persistedSummaryForOneShotResult(flow.runtimeRoot, item) : undefined;
			flow.updateDashboard({
				reuseNotice: item.reuseNotice,
				agent: item.agent,
				kind: item.kind ?? "oneshot",
				message: dashboardMessageForOneShotResult(item, persistedSummary),
				messageProvenance: dashboardMessageProvenanceForOneShotResult(item, persistedSummary),
				model: item.model,
				effort: item.effort,
				sessionMode: item.sessionMode,
				sessionKey: item.sessionKeyExplicit ? item.sessionKey : undefined,
				status: singleResultStatus(item),
				task: item.task,
				taskId: item.taskId ?? `${item.agent}-${index}`,
				transcriptPath: item.transcriptPath,
				updatedAt: new Date().toISOString(),
				usage: item.usage,
			});
		};
		const taskAgent = flow.agents.find((agent) => agent.name === t.agent);
		try {
			const result = await withChildBudget(flow.pi, flow.cwd, flow.signal, async () => runsInPane(taskAgent, lane)
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
					flow.modelRegistry,
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
								void updateOneshotDashboard(partial.details.results[0]);
								emitParallelUpdate();
							}
						},
						flow.makeDetails("parallel"),
						t.sessionKey,
						t.sameSession ?? flow.sameSession,
					flow.modelRegistry,
					));
			allResults[index] = result;
			if (!runsInPane(taskAgent, lane) || singleResultStatus(result) === "refused") await updateOneshotDashboard(result, true);
			emitParallelUpdate();
			return result;
		} catch (error) {
			const errorMessage = error instanceof Error ? error.message : String(error);
			const failed: SingleResult = {
				...allResults[index],
				exitCode: 1,
				stderr: errorMessage,
				stopReason: "error",
				errorMessage,
			};
			allResults[index] = failed;
			if (!runsInPane(taskAgent, lane)) {
				try {
					await updateOneshotDashboard(failed, false);
				} catch {
					// Dashboard update failure must not abort the pool.
				}
			}
			emitParallelUpdate();
			return failed;
		}
	}, flow.signal);

	const successCount = results.filter((r) => singleResultStatus(r) === "completed").length;
	const needsCompletionCount = results.filter(singleResultNeedsCompletion).length;
	const perResultLimits = parallelResultLimits(flow.cwd, results.length);
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
	const sections = preparedResults.map(formatPreparedParallelSection);
	const needsCompletionSuffix = needsCompletionCount > 0 ? `, ${needsCompletionCount} needs completion` : "";
	return {
		content: [{ type: "text", text: `Parallel: ${successCount}/${results.length} succeeded${needsCompletionSuffix}\n\n${sections.join("\n\n")}` }],
		details: flow.makeDetails("parallel")(preparedResults.map((prepared) => prepared.result)),
	};
}

export async function runSingleDispatch(
	flow: DispatchFlowContext & { agent: string; task: string; cwdOverride?: string; sessionKey?: string },
): Promise<ToolTextResult> {
	const lane = await resolvePaneLane(flow, [flow.agent]);
	return withPaneFallbackNotice(await singleDispatch(flow, lane), lane, flow.agents);
}

async function singleDispatch(
	flow: DispatchFlowContext & { agent: string; task: string; cwdOverride?: string; sessionKey?: string },
	lane: PaneLane,
): Promise<ToolTextResult> {
	const agent = flow.agents.find((candidate) => candidate.name === flow.agent);
	const result = await withChildBudget(flow.pi, flow.cwd, flow.signal, async () => runsInPane(agent, lane)
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
					flow.modelRegistry,
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
				flow.sameSession,
				flow.modelRegistry,
			));
	if (!runsInPane(agent, lane) || singleResultStatus(result) === "refused") {
		flow.updateDashboard({
			reuseNotice: result.reuseNotice,
			agent: result.agent,
			kind: result.kind ?? "oneshot",
			message: await dashboardMessageForCompletedOneShotResult(flow.runtimeRoot, result),
			messageProvenance: dashboardMessageProvenanceForOneShotResult(result, await persistedSummaryForOneShotResult(flow.runtimeRoot, result)),
			model: result.model,
			effort: result.effort,
			sessionMode: result.sessionMode,
			sessionKey: result.sessionKeyExplicit ? result.sessionKey : undefined,
			status: singleResultStatus(result),
			task: result.task,
			taskId: result.taskId ?? result.agent,
			transcriptPath: result.transcriptPath,
			updatedAt: new Date().toISOString(),
			usage: result.usage,
		});
	}
	if (singleResultNeedsCompletion(result)) {
		const message = needsCompletionMessage(result);
		const prepared = await prepareSingleResultForReturn(result, flow.runtimeRoot, flow.cwd, "single-needs-completion", message);
		const details = flow.makeDetails("single")([prepared.result]);
		return {
			content: [{ type: "text", text: prepared.text || message }],
			details: detailsWithTruncation(details, prepared),
		};
	}
	const isError = singleResultIsError(result);
	if (isError) {
		const errorMsg = result.errorMessage || result.stderr || getFinalOutput(result.messages) || "(no output)";
		const prepared = await prepareSingleResultForReturn(result, flow.runtimeRoot, flow.cwd, "single-error", errorMsg);
		prepared.result.errorMessage = prepared.text || errorMsg;
		const details = flow.makeDetails("single")([prepared.result]);
		return {
			content: [{ type: "text", text: `Agent ${singleResultStatus(result)}: ${prepared.text || "(no output)"}` }],
			details: detailsWithTruncation(details, prepared),
			isError: true,
		};
	}
	const prepared = await prepareSingleResultForReturn(result, flow.runtimeRoot, flow.cwd, "single");
	const details = flow.makeDetails("single")([prepared.result]);
	return {
		content: [{ type: "text", text: [result.reuseNotice, prepared.text || "(no output)"].filter(Boolean).join("\n") }],
		details: detailsWithTruncation(details, prepared),
	};
}
