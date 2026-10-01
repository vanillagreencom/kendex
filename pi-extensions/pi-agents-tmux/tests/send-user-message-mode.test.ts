// Pi 0.75 requires an explicit delivery mode when sendUserMessage may run while streaming.
// These subagent dispatch paths are timer/poller-driven, so keep the mode explicit.

import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { readTaskRegistry, recordTaskDispatchFailure, writeTaskRegistry } from "../extensions/subagent/tasks.js";

const source = readFileSync(join(import.meta.dir, "../extensions/subagent/index.ts"), "utf8");
const inboxSource = readFileSync(join(import.meta.dir, "../extensions/subagent/child-inbox.ts"), "utf8");

describe("subagent sendUserMessage delivery modes", () => {
	test("rate-limit watchdog sends recovery as an explicit steer", () => {
		expect(source).toContain('sendUserMessage: (message) => pi.sendUserMessage(message, { deliverAs: "steer" }),');
		expect(source).not.toContain("pi.sendUserMessage(message);");
	});

	test("child inbox task dispatch awaits explicit follow-up delivery", () => {
		expect(inboxSource).toContain('await pi.sendUserMessage(prompt, { deliverAs: "followUp" });');
		expect(inboxSource).not.toContain("pi.sendUserMessage(prompt);");
	});

	test("child dispatch failure restores processing file to inbox and requeues task", async () => {
		const runtimeRoot = mkdtempSync(join(tmpdir(), "subagent-dispatch-failure-"));
		try {
			const inbox = join(runtimeRoot, "inbox", "rust");
			const processingDir = join(runtimeRoot, "processing", "rust");
			mkdirSync(inbox, { recursive: true });
			mkdirSync(processingDir, { recursive: true });
			const sourcePath = join(inbox, "task-1.md");
			const processing = join(processingDir, "task-1.md");
			writeFileSync(processing, "Do work", "utf8");
			await writeTaskRegistry(runtimeRoot, {
				"task-1": {
					agent: "rust",
					createdAt: "2026-05-17T00:00:00.000Z",
					inboxFile: sourcePath,
					kind: "pane",
					outboxFile: join(runtimeRoot, "outbox", "rust", "task-1.json"),
					processingFile: processing,
					status: "running",
					task: "Do work",
					taskId: "task-1",
					updatedAt: "2026-05-17T00:00:00.000Z",
				},
			});

			const result = await recordTaskDispatchFailure(runtimeRoot, "task-1", { processing, source: sourcePath }, "dispatch failed");
			const registry = await readTaskRegistry(runtimeRoot);
			const record = registry["task-1"]!;

			expect(result).toEqual({ restoredToInbox: true, status: "queued" });
			expect(existsSync(sourcePath)).toBe(true);
			expect(existsSync(processing)).toBe(false);
			expect(record.status).toBe("queued");
			expect(record.processingFile).toBeUndefined();
			expect(record.inboxFile).toBe(sourcePath);
			expect(record.diagnostics).toContain("dispatch failed");
		} finally {
			rmSync(runtimeRoot, { force: true, recursive: true });
		}
	});
});
