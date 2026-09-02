import * as fs from "node:fs";
import * as path from "node:path";
import { safeFileName } from "./names.js";
import { piUserDir } from "./settings.js";
import type { PaneTaskRecord, TaskArtifactPaths } from "./types.js";

export function registryPath(runtimeRoot: string): string {
	return path.join(runtimeRoot, "panes.json");
}

export function taskRegistryPath(runtimeRoot: string): string {
	return path.join(runtimeRoot, "tasks.json");
}

export function transcriptDir(runtimeRoot: string): string {
	return path.join(runtimeRoot, "transcripts");
}

export function paneSessionPath(runtimeRoot: string, agentName: string): string {
	return path.join(runtimeRoot, "sessions", `${safeFileName(agentName)}.jsonl`);
}

export function hasSavedPaneSession(runtimeRoot: string, agentName: string): boolean {
	try {
		const stat = fs.statSync(paneSessionPath(runtimeRoot, agentName));
		return stat.isFile() && stat.size > 0;
	} catch {
		return false;
	}
}

export function archivedPaneSessionDir(runtimeRoot: string): string {
	return path.join(runtimeRoot, "sessions", "archived");
}

export function archivedPaneSessions(runtimeRoot: string, agentName: string): string[] {
	const safeName = safeFileName(agentName);
	const dir = archivedPaneSessionDir(runtimeRoot);
	try {
		return fs.readdirSync(dir)
			.filter((file) => file.startsWith(`${safeName}-`) && file.endsWith(".jsonl"))
			.map((file) => path.join(dir, file))
			.filter((file) => fs.statSync(file).isFile())
			.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
	} catch {
		return [];
	}
}

export function oneShotTranscriptPath(runtimeRoot: string, agentName: string, label: string): string {
	return path.join(transcriptDir(runtimeRoot), safeFileName(agentName), `${safeFileName(label)}.jsonl`);
}

export function outboxRoot(runtimeRoot: string): string {
	return path.join(runtimeRoot, "outbox");
}

export function completionPath(runtimeRoot: string, agentName: string, taskId: string): string {
	return path.join(outboxRoot(runtimeRoot), safeFileName(agentName), `${safeFileName(taskId)}.json`);
}

export function inboxDir(runtimeRoot: string, agentName: string): string {
	return path.join(runtimeRoot, "inbox", safeFileName(agentName));
}

export function processingDir(runtimeRoot: string, agentName: string): string {
	return path.join(runtimeRoot, "processing", safeFileName(agentName));
}

export function doneDir(runtimeRoot: string, agentName: string): string {
	return path.join(runtimeRoot, "done", safeFileName(agentName));
}

export function taskMarkdownPath(runtimeRoot: string, dirName: "inbox" | "processing" | "done", agentName: string, taskId: string): string {
	return path.join(runtimeRoot, dirName, safeFileName(agentName), `${safeFileName(taskId)}.md`);
}

export function completionArchiveDir(runtimeRoot: string, agentName: string): string {
	return path.join(runtimeRoot, "processed", safeFileName(agentName));
}

export function taskArtifactPaths(runtimeRoot: string, record: Pick<PaneTaskRecord, "agent" | "taskId" | "inboxFile" | "processingFile" | "doneFile" | "outboxFile" | "completionArchivePath" | "transcriptPath">): TaskArtifactPaths {
	return {
		inboxFile: record.inboxFile ?? taskMarkdownPath(runtimeRoot, "inbox", record.agent, record.taskId),
		processingFile: record.processingFile ?? taskMarkdownPath(runtimeRoot, "processing", record.agent, record.taskId),
		doneFile: record.doneFile ?? taskMarkdownPath(runtimeRoot, "done", record.agent, record.taskId),
		outboxFile: record.outboxFile ?? completionPath(runtimeRoot, record.agent, record.taskId),
		completionArchivePath: record.completionArchivePath,
		transcriptPath: record.transcriptPath,
	};
}

export function piPackageRuntimeRoots(): string[] {
	return [path.join(piUserDir(), "kendex", "sessions")];
}

