import * as fs from "node:fs";
import { formatSize, getMarkdownTheme, type Theme } from "@earendil-works/pi-coding-agent";
import { Container, Markdown, Spacer } from "@earendil-works/pi-tui";
import { sanitizeCwdSnapshot } from "./cwd-snapshot.js";
import { dashboardTraceRef } from "./dashboard.js";
import {
	addArtifactPathSection,
	addSectionHeading,
	agentStatusLine,
	agentsCommandBullet,
	compactPath,
	COMPLETION_SUMMARY_UNAVAILABLE,
	completionBodyWithoutPromptEcho,
	formatUsageStats,
	framedComponent,
	framedMessage,
	oneLinePreview,
	shortTaskId,
	subagentBranch,
	wrapAnsiLines,
	wrappedText,
	toolChromeRule,
	agentsCommandArtifactLine,
} from "./format.js";
import {
	type AgentsCommandMessageDetails,
	ICONS,
	type PaneCompletionMessageDetails,
	type PaneTaskRecord,
	type PaneTaskRegistry,
	type PaneTaskStatus,
} from "./types.js";

export function paneCompletionIcon(status: PaneTaskStatus, theme: Theme): string {
	if (status === "completed") return theme.fg("success", ICONS.check);
	if (status === "blocked") return theme.fg("error", ICONS.times);
	if (status === "failed") return theme.fg("error", ICONS.times);
	if (status === "needs_completion") return theme.fg("warning", ICONS.warning);
	if (status === "queued") return theme.fg("warning", ICONS.clock);
	return theme.fg("muted", ICONS.dotSmall);
}

export function paneCompletionStatus(status: PaneTaskStatus, theme: Theme): string {
	if (status === "completed") return theme.fg("success", status);
	if (status === "needs_completion") return theme.fg("warning", "needs completion");
	if (status === "blocked") return theme.fg("warning", status);
	if (status === "failed") return theme.fg("error", status);
	return theme.fg("muted", status);
}

export function paneCompletionTone(status: PaneTaskStatus): "success" | "warning" | "error" | "muted" {
	if (status === "completed") return "success";
	if (status === "blocked" || status === "queued" || status === "needs_completion") return "warning";
	if (status === "failed") return "error";
	return "muted";
}

export function renderAgentsCommandMessage(message: { content: string; details?: unknown }, _options: unknown, theme: Theme) {
	const details = message.details && typeof message.details === "object" ? (message.details as AgentsCommandMessageDetails) : undefined;
	const action = details?.action;
	const error = details?.error ?? (/^Error:\s*/.test(message.content) ? message.content.replace(/^Error:\s*/, "") : undefined);

	if (error) {
		return framedMessage(
			[
				`${theme.fg("error", ICONS.times)} ${theme.fg("toolTitle", theme.bold("/agents error"))}`,
				`${subagentBranch(theme, "└")}${theme.fg("error", error)}`,
			].join("\n"),
			theme,
		);
	}

	if (action === "send" && details?.agent) {
		return {
			invalidate() {},
			render(width: number): string[] {
				const rule = toolChromeRule(theme, width);
				const session = details.status ? `${theme.fg("dim", " · ")}${theme.fg("muted", String(details.status))}` : "";
				const taskSuffix = details.taskId ? `${session}${theme.fg("dim", " · ")}${theme.fg("muted", shortTaskId(details.taskId))}` : session;
				const lines = [
					agentStatusLine(theme, details.agent!, "Queued task", "warning", taskSuffix),
					agentsCommandArtifactLine(theme, "├", "inbox", details.inboxFile, width),
					agentsCommandArtifactLine(theme, "├", "completion", details.outboxFile, width),
					agentsCommandArtifactLine(theme, "└", "transcript", details.transcriptPath, width),
				];
				return [rule, ...lines.flatMap((line) => wrapAnsiLines(line, width)), rule];
			},
		};
	}

	if (action === "start" && details?.agent) {
		return framedMessage(
			[
				agentStatusLine(theme, details.agent, String(details.status ?? "started"), "success", theme.fg("dim", ` · ${details.windowName ?? "pane"}`)),
				`${subagentBranch(theme, "└")}${theme.fg("muted", "session ")}${theme.fg("toolOutput", compactPath(details.sessionFile))}`,
			].join("\n"),
			theme,
		);
	}

	if (action === "attach" && details?.agent) {
		return framedMessage(agentStatusLine(theme, details.agent, "attached", "success"), theme);
	}

	if (action === "stop" && details?.agent) {
		return framedMessage(agentStatusLine(theme, details.agent, "stopped", "success"), theme);
	}

	if (action === "collect") {
		const count = Number.isFinite(Number(details?.count)) ? Number(details?.count) : undefined;
		return framedMessage(`${agentsCommandBullet(theme)}${theme.fg("toolTitle", theme.bold("/agents collect "))}${theme.fg("success", `${count ?? 0} completion${count === 1 ? "" : "s"}`)}`, theme);
	}

	if (action === "toggle") {
		return framedMessage(`${agentsCommandBullet(theme)}${theme.fg("toolTitle", theme.bold("/agents toggle "))}${theme.fg("success", details?.status ?? oneLinePreview(message.content, 80))}`, theme);
	}

	if (message.content.trim().startsWith("#") || message.content.includes("\n| ---")) {
		return framedComponent(new Markdown(message.content, 0, 0, getMarkdownTheme()), theme);
	}

	return framedMessage(`${agentsCommandBullet(theme)}${theme.fg("toolTitle", theme.bold("/agents "))}${theme.fg("toolOutput", message.content)}`, theme);
}

export function renderPaneCompletionMessage(message: { content: string; details?: unknown }, options: { expanded?: boolean } | undefined, theme: Theme) {
	const details = message.details as PaneCompletionMessageDetails | undefined;
	const completions = details?.completions ?? [];
	if (completions.length === 0) return wrappedText(message.content);
	const expanded = Boolean(options?.expanded);
	if (!expanded) {
		const lines: string[] = [];
		for (const detail of completions) {
			lines.push(agentStatusLine(theme, detail.agent, detail.status, paneCompletionTone(detail.status), theme.fg("dim", ` · ${shortTaskId(detail.taskId)} · ctrl+o to expand`)));
			lines.push(`${subagentBranch(theme, "└")}${theme.fg("toolOutput", oneLinePreview(detail.summary, 120) || "No summary provided.")}`);
		}
		return framedMessage(lines.join("\n"), theme);
	}

	const container = new Container();
	container.addChild(wrappedText(theme.fg("toolTitle", theme.bold(`Agent completion${completions.length === 1 ? "" : "s"} (${completions.length})`))));
	for (const [index, detail] of completions.entries()) {
		if (index > 0) container.addChild(new Spacer(1));
		container.addChild(wrappedText(agentStatusLine(theme, detail.agent, detail.status, paneCompletionTone(detail.status), theme.fg("dim", ` · ${detail.taskId}`))));
		addSectionHeading(container, theme, "Summary");
		container.addChild(wrappedText(detail.summary || "No summary provided."));
		addSectionHeading(container, theme, "Files Changed");
		container.addChild(wrappedText(detail.filesChanged.length ? detail.filesChanged.map((file) => `- ${file}`).join("\n") : "None reported"));
		addSectionHeading(container, theme, "Validation");
		container.addChild(wrappedText(detail.validation.length ? detail.validation.map((item) => `- ${item}`).join("\n") : "None reported"));
		if (detail.notes) {
			addSectionHeading(container, theme, "Notes");
			container.addChild(wrappedText(detail.notes));
		}
		addSectionHeading(container, theme, "Artifacts");
		addArtifactPathSection(container, theme, "Source", detail.sourcePath);
		addArtifactPathSection(container, theme, "Archive", detail.archivePath);
		addArtifactPathSection(container, theme, "Transcript", detail.transcriptPath);
	}
	return framedComponent(container, theme);
}

export function formatTaskRecordResult(record: PaneTaskRecord, verbose = false): string {
	const files = record.filesChanged?.length ? record.filesChanged.map((file) => `- ${file}`).join("\n") : "None reported";
	const validation = record.validation?.length ? record.validation.map((item) => `- ${item}`).join("\n") : "None reported";
	const diagnostics = record.diagnostics?.length ? record.diagnostics.map((item) => `- ${item}`).join("\n") : "";
	const cwdSnapshot = record.cwdSnapshot ? formatCwdSnapshot(record.cwdSnapshot) : "";
	const terminal = record.status === "completed" || record.status === "failed" || record.status === "blocked";
	const summary = record.summary?.trim()
		? completionBodyWithoutPromptEcho(record.summary, record.task)
		: record.status === "needs_completion"
			? "Task turn ended without a valid completion record; see diagnostics."
			: terminal
				? COMPLETION_SUMMARY_UNAVAILABLE
				: "No summary yet.";
	const usage = record.usage ? formatUsageStats(record.usage, record.model) : "";
	const metaParts = [
		`Status: **${record.status}**`,
		record.model ? `Model: ${record.model}` : "",
		usage ? `Usage: ${usage}` : "",
		record.completedAt ? `Completed: ${record.completedAt}` : record.updatedAt ? `Updated: ${record.updatedAt}` : `Created: ${record.createdAt}`,
	].filter(Boolean);
	const lines = [
		`## ${record.agent} · ${record.taskId}`,
		metaParts.join(" · "),
		"",
		"### Summary",
		summary,
		"",
		"### Files Changed",
		files,
		"",
		"### Validation",
		validation,
		record.notes ? `\n### Notes\n${record.notes}` : "",
		cwdSnapshot ? `\n### CWD Snapshot\n${cwdSnapshot}` : "",
		diagnostics ? `\n### Diagnostics\n${diagnostics}` : "",
	];
	if (verbose) {
		lines.push("", "### Task", record.task || "(task text unavailable)");
		const artifactLines = [
			record.inboxFile ? `Inbox: ${record.inboxFile}` : "",
			record.processingFile ? `Processing: ${record.processingFile}` : "",
			record.doneFile ? `Done: ${record.doneFile}` : "",
			record.outboxFile ? `Expected outbox: ${record.outboxFile}` : "",
			record.completionArchivePath ? `Archive: ${record.completionArchivePath}` : record.completionSourcePath ? `Source: ${record.completionSourcePath}` : "",
			record.transcriptPath ? `Transcript: ${record.transcriptPath}` : "",
		].filter(Boolean);
		if (artifactLines.length > 0) lines.push("", "### Artifacts", ...artifactLines);
	} else {
		const artifactLines = [
			record.completionArchivePath ? `Archive: ${compactPath(record.completionArchivePath)}` : "",
			record.transcriptPath ? `Transcript: ${compactPath(record.transcriptPath)}` : "",
		].filter(Boolean);
		if (artifactLines.length > 0) lines.push("", ...artifactLines);
	}
	return lines.filter(Boolean).join("\n");
}

function formatCwdSnapshot(snapshot: PaneTaskRecord["cwdSnapshot"]): string {
	snapshot = sanitizeCwdSnapshot(snapshot);
	if (!snapshot) return "";
	const dirty = snapshot.dirty ? "dirty" : "clean";
	const lines = [
		`CWD: ${snapshot.cwd}`,
		`HEAD: ${snapshot.head.slice(0, 12)} (${dirty})`,
		`Last commit: ${snapshot.lastCommit.subject}`,
	];
	if (snapshot.status.trim()) lines.push("Status:", "```", snapshot.status, "```");
	return lines.join("\n");
}

export function recordTraceRef(record: PaneTaskRecord): string {
	return dashboardTraceRef({ agent: record.agent, kind: record.kind ?? (record.paneId ? "pane" : "oneshot"), taskId: record.taskId, transcriptPath: record.transcriptPath });
}

export function recordTimestamp(record: PaneTaskRecord): number {
	const value = Date.parse(record.completedAt ?? record.createdAt ?? "");
	return Number.isFinite(value) ? value : 0;
}

export function resolveTraceRecord(records: PaneTaskRegistry, query: string): PaneTaskRecord | undefined {
	const needle = query.trim();
	if (!needle) return undefined;
	if (records[needle]) return records[needle];
	const normalized = needle.toLowerCase();
	const candidates = Object.values(records).filter((record) => {
		const ref = recordTraceRef(record).toLowerCase();
		return ref === normalized || ref.includes(normalized) || record.taskId.toLowerCase().includes(normalized) || record.agent.toLowerCase() === normalized;
	});
	return candidates.sort((a, b) => recordTimestamp(b) - recordTimestamp(a))[0];
}

export async function readTextFileIfExists(filePath: string | undefined, maxBytes = 24_000): Promise<string> {
	if (!filePath) return "";
	try {
		const content = await fs.promises.readFile(filePath, "utf-8");
		return content.length > maxBytes ? `${content.slice(Math.max(0, content.length - maxBytes))}\n\n[truncated: showing last ${formatSize(maxBytes)}]` : content;
	} catch {
		return "";
	}
}

export async function formatTraceView(record: PaneTaskRecord, verbose = false): Promise<string> {
	const base = formatTaskRecordResult(record, true);
	const transcript = await readTextFileIfExists(record.transcriptPath, verbose ? 80_000 : 24_000);
	const completion = await readTextFileIfExists(record.completionArchivePath ?? record.completionSourcePath, 12_000);
	return [
		`# Trace ${recordTraceRef(record)}`,
		"",
		base,
		completion ? `\n## Completion JSON\n\`\`\`json\n${completion}\n\`\`\`` : "",
		transcript ? `\n## Transcript tail\n\`\`\`jsonl\n${transcript}\n\`\`\`` : "",
	].filter(Boolean).join("\n");
}
