import * as fs from "node:fs/promises";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { completionPath, inboxDir, processingDir } from "./paths.js";
import { emitSubagentEvent, recordTaskDispatchFailure, updateTaskRegistry } from "./tasks.js";

/** Claim and deliver one pane task. A failed claim is restored before its ownership is released. */
export async function pollChildInbox(
	runtimeRoot: string, agent: string, pi: ExtensionAPI, ctx: ExtensionContext,
	claim: (file: string) => void, release: (file: string) => void,
): Promise<void> {
	let paths: { source: string; processing: string } | undefined;
	try {
		const inbox = inboxDir(runtimeRoot, agent);
		let files: string[];
		try { files = (await fs.readdir(inbox)).filter((file) => file.endsWith(".md")).sort(); }
		catch (error) {
			if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
			throw error;
		}
		if (!files[0]) return;
		const source = path.join(inbox, files[0]);
		const processing = path.join(processingDir(runtimeRoot, agent), files[0]);
		await fs.mkdir(path.dirname(processing), { recursive: true, mode: 0o700 });
		try { await fs.rename(source, processing); }
		catch (error) {
			// Another pane can claim the same file before this rename.
			if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
			throw error;
		}
		paths = { source, processing };
		claim(processing);
		const prompt = await fs.readFile(processing, "utf-8");
		const taskId = path.basename(processing, path.extname(processing));
		const now = new Date().toISOString();
		await updateTaskRegistry(runtimeRoot, (records) => {
			const existing = records[taskId];
			records[taskId] = {
				...existing, taskId, agent: existing?.agent ?? agent, task: existing?.task ?? "",
				status: "running", kind: "pane", inboxFile: existing?.inboxFile ?? source, processingFile: processing,
				outboxFile: existing?.outboxFile ?? completionPath(runtimeRoot, agent, taskId),
				transcriptPath: existing?.transcriptPath ?? ctx.sessionManager.getSessionFile() ?? undefined,
				createdAt: existing?.createdAt ?? now, updatedAt: now,
			};
		});
		emitSubagentEvent(pi, "subagents:started", {
			mode: "pane", agent, taskId, status: "running", runtimeRoot,
			transcriptPath: ctx.sessionManager.getSessionFile() ?? undefined,
			completionPath: completionPath(runtimeRoot, agent, taskId),
		});
		ctx.ui.setStatus("agent", `${agent} running ${files[0]}`);
		await pi.sendUserMessage(prompt, { deliverAs: "followUp" });
	} catch (error) {
		if (paths) {
			try {
				await recordTaskDispatchFailure(runtimeRoot, path.basename(paths.processing, ".md"), paths, String(error));
			} catch (recoveryError) {
				throw new AggregateError([error, recoveryError], `Child inbox claim and recovery failed: ${String(error)}; ${String(recoveryError)}`);
			} finally {
				release(paths.processing);
				ctx.ui.setStatus("agent", `${agent} idle`);
			}
		}
		throw error;
	}
}
