import { getMarkdownTheme } from "@earendil-works/pi-coding-agent";
import { Container, Markdown, Spacer, truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { discoverAgents, type AgentScope } from "./agents.js";
import {
	addArtifactPathSection,
	addSectionHeading,
	addWrappedSection,
	agentStatusLine,
	agentsCommandBullet,
	agentWord,
	ansiMagenta,
	compactPath,
	finalOutputLooksLikeToolEcho,
	finalResponseSuppressedLine,
	formatToolCall,
	formatUsageStats,
	getDisplayItems,
	getFinalOutput,
	oneLinePreview,
	subagentBranch,
	wrappedText,
} from "./format.js";
import { dashboardEnabled, quietInline, settingNumber } from "./settings.js";
import {
	COLLAPSED_ITEM_COUNT,
	ICONS,
	type DisplayItem,
	type SingleResult,
	type SubagentDetails,
	type UsageStats,
} from "./types.js";

export const subagentToolRenderers = {
	renderCall(args: any, theme: any, _context: any) {
		const scope: AgentScope = args.agentScope ?? "project";
		if (args.chain && args.chain.length > 0) {
			let text =
				theme.fg("toolTitle", theme.bold("agents ")) +
				theme.fg("accent", `chain (${args.chain.length} steps)`) +
				theme.fg("muted", ` [${scope}]`);
			for (let i = 0; i < Math.min(args.chain.length, 3); i++) {
				const step = args.chain[i];
				const cleanTask = step.task.replace(/\{previous\}/g, "").trim();
				const preview = cleanTask.length > 40 ? `${cleanTask.slice(0, 40)}...` : cleanTask;
				text +=
					"\n  " +
					theme.fg("muted", `${i + 1}.`) +
					" " +
					theme.fg("accent", step.agent) +
					theme.fg("dim", ` ${preview}`);
			}
			if (args.chain.length > 3) text += `\n  ${theme.fg("muted", `... +${args.chain.length - 3} more`)}`;
			return wrappedText(text);
		}
		if (args.tasks && args.tasks.length > 0) {
			return new Container();
		}
		const agentName = args.agent || "...";
		try {
			const agent = discoverAgents(_context?.cwd ?? process.cwd(), scope).agents.find((candidate) => candidate.name === agentName);
			if (agent?.pane) return new Container();
		} catch {
			// Keep the generic call preview if discovery fails.
		}
		const preview = args.task ? oneLinePreview(args.task, 56) : "...";
		let text = `${agentsCommandBullet(theme)}${agentWord(theme)} ${ansiMagenta(theme.bold(agentName))}`;
		if (scope !== "project") text += theme.fg("dim", ` · ${scope}`);
		text += `\n${subagentBranch(theme, "└", _context?.cwd)}${theme.fg("dim", preview)}`;
		return wrappedText(text);
	},

	renderResult(result: any, { expanded }: { expanded?: boolean }, theme: any, context: any) {
		const cwd = context?.cwd;
		const collapsedItemCount = Math.max(1, Math.floor(settingNumber("collapsedItemCount", COLLAPSED_ITEM_COUNT, context?.cwd)));
		const details = result.details as SubagentDetails | undefined;
		if (!details || details.results.length === 0) {
			const text = result.content[0];
			return wrappedText(text?.type === "text" ? text.text : "(no output)");
		}

		const mdTheme = getMarkdownTheme();
		const truncationBadge = (r: SingleResult) => (r.truncation?.truncated ? theme.fg("warning", " · truncated") : "");
		const fullOutputLine = (r: SingleResult) =>
			r.fullOutputPath
				? theme.fg("dim", `Full output: ${compactPath(r.fullOutputPath)}`)
				: r.fullOutputError
					? theme.fg("warning", `Full output unavailable: ${r.fullOutputError}`)
					: "";
		const transcriptLine = (r: SingleResult) => (r.transcriptPath ? theme.fg("dim", `Transcript: ${compactPath(r.transcriptPath)}`) : "");
		const queuedPaneLine = (r: SingleResult, _dashboard = false) => {
			if (!r.taskId || !r.paneId) return "";
			const mode = r.paneSessionMode === "live" ? "reused live pane" : r.paneSessionMode === "resumed" ? "resumed pane" : "new pane";
			const suffix = `${theme.fg("dim", ` · ${mode}`)}${theme.fg("dim", " · ctrl+o expand")}`;
			return agentStatusLine(theme, r.agent, "Queued task", "warning", suffix);
		};
		const queuedTaskPreviewComponent = (r: SingleResult, dashboard = false) => ({
			invalidate() {},
			render(width: number): string[] {
				const header = queuedPaneLine(r, dashboard);
				const task = r.task.replace(/\s+/g, " ").trim() || "queued task";
				const firstPrefix = subagentBranch(theme, "└", cwd);
				const nextPrefix = " ".repeat(Math.max(0, visibleWidth(firstPrefix)));
				const textWidth = Math.max(20, width - Math.max(visibleWidth(firstPrefix), visibleWidth(nextPrefix)));
				const wrapped = wrapTextWithAnsi(task, textWidth);
				const shown = wrapped.slice(0, 2);
				if (wrapped.length > shown.length && shown.length > 0) shown[shown.length - 1] = truncateToWidth(`${shown[shown.length - 1]}…`, textWidth, "…");
				return [
					header,
					`${firstPrefix}${theme.fg("dim", shown[0] ?? "queued task")}`,
					...(shown[1] ? [`${nextPrefix}${theme.fg("dim", shown[1])}`] : []),
				];
			},
		});
		const expandedQueuedTaskComponent = (r: SingleResult) => {
			const container = new Container();
			container.addChild(wrappedText(queuedPaneLine(r)));
			addSectionHeading(container, theme, "Queued task");
			container.addChild(new Markdown(r.task.trim() || "(empty task)", 0, 0, mdTheme));
			if (r.taskId || r.queuedTaskFile || r.queuedOutboxFile || r.transcriptPath) {
				if (r.paneSessionMode) addWrappedSection(container, theme, "Pane session", r.paneSessionMode === "live" ? "Reused live pane" : r.paneSessionMode === "resumed" ? "Resumed saved pane session" : "Started new pane session", "dim");
				if (r.taskId) addWrappedSection(container, theme, "Task ID", r.taskId, "dim");
				addArtifactPathSection(container, theme, "Inbox", r.queuedTaskFile);
				addArtifactPathSection(container, theme, "Completion", r.queuedOutboxFile);
				addArtifactPathSection(container, theme, "Transcript", r.transcriptPath);
			}
			return container;
		};
		const addFinalResponseMarkdown = (container: Container, finalOutput: string, toolCalls: DisplayItem[]) => {
			if (!finalOutput.trim()) {
				container.addChild(wrappedText(theme.fg("muted", "(no final response)")));
				return;
			}
			if (finalOutputLooksLikeToolEcho(finalOutput, toolCalls)) {
				container.addChild(wrappedText(finalResponseSuppressedLine(theme)));
				return;
			}
			container.addChild(new Markdown(finalOutput.trim(), 0, 0, mdTheme));
		};

		const renderDisplayItems = (items: DisplayItem[], limit?: number) => {
			const toShow = limit ? items.slice(-limit) : items;
			const skipped = limit && items.length > limit ? items.length - limit : 0;
			let text = "";
			if (skipped > 0) text += theme.fg("muted", `... ${skipped} earlier items\n`);
			for (const [index, item] of toShow.entries()) {
				const branch = subagentBranch(theme, index === toShow.length - 1 ? "└" : "├", cwd);
				if (item.type === "text") {
					const preview = expanded ? item.text : item.text.split("\n").slice(0, 3).join("\n");
					const lines = preview.split(/\r?\n/);
					text += `${branch}${theme.fg("toolOutput", lines[0] ?? "")}\n`;
					for (const line of lines.slice(1)) text += `${subagentBranch(theme, "│", cwd)}${theme.fg("toolOutput", line)}\n`;
				} else {
					text += `${branch}${formatToolCall(item.name, item.args, theme.fg.bind(theme))}\n`;
				}
			}
			return text.trimEnd();
		};

		if (details.mode === "single" && details.results.length === 1) {
			const r = details.results[0];
			if (r.duplicateQueued) return new Container();
			// runSingleAgent uses exitCode -1 as the still-running sentinel while
			// emitting streaming partials; only a positive exitCode (or a terminal
			// stopReason) is a real failure.
			const isRunning = r.exitCode === -1;
			const needsCompletion = r.status === "needs_completion";
			const isError = !needsCompletion && !isRunning && (r.exitCode > 0 || r.stopReason === "error" || r.stopReason === "aborted");
			const isQueued = !needsCompletion && !isError && !isRunning && Boolean(r.taskId && r.paneId);
			const displayItems = getDisplayItems(r.messages);
			const finalOutput = getFinalOutput(r.messages);
			const queued = queuedPaneLine(r);
			const quietDashboard = !expanded && dashboardEnabled(cwd) && quietInline(cwd);

			if (expanded) {
				if (isQueued) return expandedQueuedTaskComponent(r);
				const container = new Container();
				const statusLabel = isQueued ? "Queued task" : isRunning ? "working" : needsCompletion ? "needs completion" : isError ? "failed" : "completed";
				const statusTone = isQueued || isRunning || needsCompletion ? "warning" : isError ? "error" : "success";
				let header = agentStatusLine(theme, r.agent, statusLabel, statusTone, theme.fg("dim", ` · ${isQueued ? "pane" : "bg"}`));
				if (isError && r.stopReason) header += ` ${theme.fg("error", `[${r.stopReason}]`)}`;
				if (needsCompletion && r.needsCompletionReason) header += ` ${theme.fg("warning", `[${r.needsCompletionReason}]`)}`;
				header += truncationBadge(r);
				container.addChild(wrappedText(header));
				if (isError && r.errorMessage) container.addChild(wrappedText(theme.fg("error", `Error: ${r.errorMessage}`)));
				if (needsCompletion && r.errorMessage) container.addChild(wrappedText(theme.fg("warning", r.errorMessage)));
				container.addChild(new Spacer(1));
				container.addChild(wrappedText(theme.fg("muted", "─── Task ───")));
				container.addChild(wrappedText(theme.fg("dim", r.task)));
				container.addChild(new Spacer(1));
				const toolCalls = displayItems.filter((item) => item.type === "toolCall");
				container.addChild(wrappedText(theme.fg("muted", "─── Tools used ───")));
				if (toolCalls.length === 0) container.addChild(wrappedText(theme.fg("muted", "(none)")));
				else {
					for (const item of toolCalls) {
						container.addChild(
							wrappedText(theme.fg("muted", "→ ") + formatToolCall(item.name, item.args, theme.fg.bind(theme))),
						);
					}
				}
				container.addChild(new Spacer(1));
				container.addChild(wrappedText(theme.fg("muted", "─── Final response ───")));
				addFinalResponseMarkdown(container, finalOutput, toolCalls);
				const outputPath = fullOutputLine(r);
				if (outputPath) container.addChild(wrappedText(outputPath));
				const transcript = transcriptLine(r);
				if (transcript) container.addChild(wrappedText(transcript));
				const usageStr = queued ? "" : formatUsageStats(r.usage, r.model);
				if (usageStr) {
					container.addChild(new Spacer(1));
					container.addChild(wrappedText(theme.fg("dim", usageStr)));
				}
				return container;
			}


			if (queued) return queuedTaskPreviewComponent(r, quietDashboard);

			if (quietDashboard && !queued && !isError && !needsCompletion) {
				const toolCalls = displayItems.filter((item) => item.type === "toolCall");
				const preview = finalOutput && !finalOutputLooksLikeToolEcho(finalOutput, toolCalls)
					? oneLinePreview(finalOutput, 180)
					: r.task
						? oneLinePreview(r.task, 140)
						: "completed";
				let text = `${theme.fg("toolTitle", theme.bold("Result from"))} ${ansiMagenta(theme.bold(r.agent))}${theme.fg("dim", " · bg · ctrl+o")}${truncationBadge(r)}`;
				if (preview) text += `\n${subagentBranch(theme, "└", cwd)}${theme.fg("toolOutput", preview)}`;
				const outputPath = fullOutputLine(r);
				if (outputPath) text += `\n${outputPath}`;
				return wrappedText(text);
			}

			const compactStatusLabel = isRunning ? "working" : needsCompletion ? "needs completion" : isError ? "failed" : "completed";
			const compactStatusTone = isRunning || needsCompletion ? "warning" : isError ? "error" : "success";
			let text = queued || agentStatusLine(theme, r.agent, compactStatusLabel, compactStatusTone, `${theme.fg("dim", " · bg")}${theme.fg("dim", " · ctrl+o")}`);
			if (isError && r.stopReason) text += ` ${theme.fg("error", `[${r.stopReason}]`)}`;
			if (needsCompletion && r.needsCompletionReason) text += ` ${theme.fg("warning", `[${r.needsCompletionReason}]`)}`;
			text += truncationBadge(r);
			if (queued) text += `\n${subagentBranch(theme, "└", cwd)}${theme.fg("dim", r.task ? oneLinePreview(r.task, 120) : "queued task")}`;
			else if (isError && r.errorMessage) text += `\n${theme.fg("error", `Error: ${r.errorMessage}`)}`;
			else if (needsCompletion && r.errorMessage) text += `\n${subagentBranch(theme, "└", cwd)}${theme.fg("warning", r.errorMessage)}`;
			else if (displayItems.length === 0) text += `\n${subagentBranch(theme, "└", cwd)}${theme.fg("dim", r.task ? oneLinePreview(r.task, 120) : "(no output)")}`;
			else {
				if (r.task) text += `\n${subagentBranch(theme, "├", cwd)}${theme.fg("dim", oneLinePreview(r.task, 120))}`;
				text += `\n${renderDisplayItems(displayItems, collapsedItemCount)}`;
				if (displayItems.length > collapsedItemCount) text += `\n${theme.fg("muted", "… more in ctrl+o")}`;
			}
			const outputPath = queued ? "" : fullOutputLine(r);
			if (outputPath) text += `\n${outputPath}`;
			const usageStr = formatUsageStats(r.usage, r.model);
			if (usageStr) text += `\n${theme.fg("dim", usageStr)}`;
			return wrappedText(text);
		}

		const aggregateUsage = (results: SingleResult[]) => {
			const total: UsageStats = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 };
			for (const r of results) {
				total.input += r.usage.input;
				total.output += r.usage.output;
				total.cacheRead += r.usage.cacheRead;
				total.cacheWrite += r.usage.cacheWrite;
				total.cost += r.usage.cost;
				total.contextTokens = Math.max(total.contextTokens, r.usage.contextTokens || 0);
				total.turns += r.usage.turns;
			}
			return total;
		};

		if (details.mode === "chain") {
			const successCount = details.results.filter((r) => r.exitCode === 0 && r.status !== "needs_completion").length;
			const runningCount = details.results.filter((r) => r.exitCode === -1).length;
			const needsCompletionCount = details.results.filter((r) => r.status === "needs_completion").length;
			const chainStepIcon = (r: SingleResult) =>
				r.status === "needs_completion"
					? theme.fg("warning", ICONS.warning)
					: r.exitCode === -1
					? theme.fg("warning", ICONS.cog)
					: r.exitCode === 0
						? theme.fg("success", ICONS.check)
						: theme.fg("error", ICONS.times);
			const icon = runningCount > 0
				? theme.fg("warning", ICONS.cog)
				: needsCompletionCount > 0
					? theme.fg("warning", ICONS.warning)
				: successCount === details.results.length
					? theme.fg("success", ICONS.check)
					: theme.fg("error", ICONS.times);

			if (expanded) {
				const container = new Container();
				container.addChild(
					wrappedText(
						icon +
							" " +
							theme.fg("toolTitle", theme.bold("chain ")) +
							theme.fg("accent", `${successCount}/${details.results.length} steps`),
					),
				);

				for (const r of details.results) {
					const rIcon = chainStepIcon(r);
					const displayItems = getDisplayItems(r.messages);
					const finalOutput = getFinalOutput(r.messages);

					container.addChild(new Spacer(1));
					container.addChild(
						wrappedText(
							`${theme.fg("muted", `─── Step ${r.step}: `) + theme.fg("accent", r.agent)} ${rIcon}${truncationBadge(r)}`,
						),
					);
					container.addChild(wrappedText(theme.fg("muted", "Task: ") + theme.fg("dim", r.task)));
					const toolCalls = displayItems.filter((item) => item.type === "toolCall");
					container.addChild(wrappedText(theme.fg("muted", "Tools used:")));
					if (toolCalls.length === 0) container.addChild(wrappedText(theme.fg("muted", "(none)")));
					else {
						for (const item of toolCalls) {
							container.addChild(
								wrappedText(theme.fg("muted", "→ ") + formatToolCall(item.name, item.args, theme.fg.bind(theme))),
							);
						}
					}

					container.addChild(wrappedText(theme.fg("muted", "Final response:")));
					addFinalResponseMarkdown(container, finalOutput, toolCalls);

					const outputPath = fullOutputLine(r);
					if (outputPath) container.addChild(wrappedText(outputPath));
					const transcript = transcriptLine(r);
					if (transcript) container.addChild(wrappedText(transcript));
					const stepUsage = formatUsageStats(r.usage, r.model);
					if (stepUsage) container.addChild(wrappedText(theme.fg("dim", stepUsage)));
				}

				const usageStr = formatUsageStats(aggregateUsage(details.results));
				if (usageStr) {
					container.addChild(new Spacer(1));
					container.addChild(wrappedText(theme.fg("dim", `Total: ${usageStr}`)));
				}
				return container;
			}

			let text =
				icon +
				" " +
				theme.fg("toolTitle", theme.bold("chain ")) +
				theme.fg("accent", `${successCount}/${details.results.length} steps`);
			for (const r of details.results) {
				const rIcon = chainStepIcon(r);
				const displayItems = getDisplayItems(r.messages);
				text += `\n\n${theme.fg("muted", `─── Step ${r.step}: `)}${theme.fg("accent", r.agent)} ${rIcon}${truncationBadge(r)}`;
				if (displayItems.length === 0) text += `\n${theme.fg("muted", "(no output)")}`;
				else text += `\n${renderDisplayItems(displayItems, 5)}`;
				const outputPath = fullOutputLine(r);
				if (outputPath) text += `\n${outputPath}`;
				const transcript = transcriptLine(r);
				if (transcript) text += `\n${transcript}`;
			}
			const usageStr = formatUsageStats(aggregateUsage(details.results));
			if (usageStr) text += `\n\n${theme.fg("dim", `Total: ${usageStr}`)}`;
			text += `\n${theme.fg("muted", "(ctrl+o to expand)")}`;
			return wrappedText(text);
		}

		if (details.mode === "parallel") {
			const running = details.results.filter((r) => r.exitCode === -1).length;
			const needsCompletionCount = details.results.filter((r) => r.status === "needs_completion").length;
			const successCount = details.results.filter((r) => r.exitCode === 0 && r.status !== "needs_completion").length;
			const failCount = details.results.filter((r) => r.exitCode > 0).length;
			const queuedPaneCount = details.results.filter((r) => r.exitCode === 0 && r.taskId && r.paneId).length;
			const oneshotCompletedCount = successCount - queuedPaneCount;
			const isRunning = running > 0;
			const total = details.results.length;
			const pluralN = (n: number) => (n === 1 ? "" : "s");
			const headerLabel = isRunning
				? `${total} agent${pluralN(total)} running`
				: needsCompletionCount > 0
					? `${needsCompletionCount}/${total} agent${pluralN(total)} need completion`
				: failCount > 0
					? `${successCount}/${total} agent${pluralN(total)} completed`
					: queuedPaneCount === total
						? `${total} agent${pluralN(total)} launched`
						: queuedPaneCount > 0
							? `${total} agents launched (${oneshotCompletedCount} bg, ${queuedPaneCount} pane)`
							: `${total} agent${pluralN(total)} completed`;
			const hint = isRunning
				? ""
				: queuedPaneCount > 0
					? theme.fg("muted", " · see dashboard for live status")
					: dashboardEnabled(cwd) && quietInline(cwd) && !expanded
						? theme.fg("muted", " · lifecycle in dashboard")
					: expanded
						? ""
						: theme.fg("muted", " (ctrl+o to inspect)");
			const headerText =
				theme.fg("accent", "● ") +
				theme.fg("toolTitle", theme.bold(headerLabel)) +
				hint;
			const nameWidth = Math.min(28, Math.max(0, ...details.results.map((r) => visibleWidth(r.agent))));
			const rowTaskPreview = (r: SingleResult, maxChars: number) =>
				r.task ? theme.fg("dim", ` · ${oneLinePreview(r.task, maxChars)}`) : "";
			const treeText = details.results
				.map((r, index) => {
					const prefix = index === details.results.length - 1 ? "└" : "├";
					const name = ((text: string, width: number) => `${text}${" ".repeat(Math.max(0, width - visibleWidth(text)))}`)(ansiMagenta(theme.bold(r.agent)), nameWidth);
					return `${subagentBranch(theme, prefix, cwd)}${name}${rowTaskPreview(r, 100)}${truncationBadge(r)}`;
				})
				.join("\n");

			return wrappedText(`${headerText}\n${treeText}`);
		}

		const text = result.content[0];
		return wrappedText(text?.type === "text" ? text.text : "(no output)");
	},
};
