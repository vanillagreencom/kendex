import assert from "node:assert/strict";
import { pollChildInbox } from "../extensions/subagent/child-inbox.js";
import { cleanupTempRuntimes, importRuntimeCopy, tempRuntime } from "./browser-fixture.js";
afterAll(cleanupTempRuntimes);
// Pi 0.75 requires an explicit delivery mode when sendUserMessage may run while streaming.
// These subagent dispatch paths are timer/poller-driven, so keep the mode explicit.

import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, test } from "bun:test";
import { readTaskRegistry, recordTaskDispatchFailure, writeTaskRegistry } from "../extensions/subagent/tasks.js";

const source = readFileSync(join(import.meta.dir, "../extensions/subagent/index.ts"), "utf8");


describe("subagent sendUserMessage delivery modes", () => {
	test("rate-limit watchdog sends recovery as an explicit steer", () => {
		expect(source).toContain('sendUserMessage: (message) => pi.sendUserMessage(message, { deliverAs: "steer" }),');
		expect(source).not.toContain("pi.sendUserMessage(message);");
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

async function inboxDelivery(poll: typeof pollChildInbox): Promise<void> {
	for (const reject of [false, true]) {
		const root = tempRuntime();
		const source = join(root, "inbox", "engineer", "work.md");
		mkdirSync(join(root, "inbox", "engineer"), { recursive: true });
		writeFileSync(source, "inspect the code");
		const delivered: Array<[string, unknown]> = [];
		let finish!: () => void;
		let fail!: (error: Error) => void;
		const gate = new Promise<void>((resolve, reject) => { finish = resolve; fail = reject; });
		const pi = { events: { emit() {} }, sendUserMessage(prompt: string, options: unknown) { delivered.push([prompt, options]); return gate; } } as unknown as Parameters<typeof poll>[2];
		const ctx = { ui: { setStatus() {} }, sessionManager: { getSessionFile() {} } } as unknown as Parameters<typeof poll>[3];
		let owner: string | undefined;
		let settled = false;
		const result = poll(root, "engineer", pi, ctx, (file) => { owner = file; }, () => { owner = undefined; });
		const observed = result.then(() => { settled = true; }, () => { settled = true; });
		try {
			// Wait for the real asynchronous claim and registry replacement, not a fake poll.
			for (let i = 0; i < 100 && delivered.length === 0 && !settled; i++) await new Promise((resolve) => setTimeout(resolve, 10));
			assert.deepEqual(delivered, [["inspect the code", { deliverAs: "followUp" }]], "inbox must deliver the claimed prompt as followUp");
			assert.equal(settled, false, "inbox must await delivery settlement");
			assert.ok(owner);
			if (reject) {
				fail(new Error("delivery rejected"));
				await assert.rejects(result, /delivery rejected/);
				assert.equal(owner, undefined);
				assert.equal(readFileSync(source, "utf8"), "inspect the code");
			} else { finish(); await result; assert.equal(existsSync(source), false); }
		} finally { finish(); await observed; }
	}
}

test("child inbox awaits actual followUp delivery and recovers rejected delivery", async () => {
	await inboxDelivery(pollChildInbox);
	const mutant = await importRuntimeCopy("child-inbox.ts", 'await pi.sendUserMessage(prompt, { deliverAs: "followUp" });', 'if (false) await pi.sendUserMessage(prompt, { deliverAs: "followUp" });') as typeof import("../extensions/subagent/child-inbox.js");
	await assert.rejects(inboxDelivery(mutant.pollChildInbox), /inbox must deliver/);
	const unawaited = await importRuntimeCopy("child-inbox.ts", 'await pi.sendUserMessage(prompt, { deliverAs: "followUp" });', 'void pi.sendUserMessage(prompt, { deliverAs: "followUp" });') as typeof import("../extensions/subagent/child-inbox.js");
	await assert.rejects(inboxDelivery(unawaited.pollChildInbox), /inbox must await/);
});
