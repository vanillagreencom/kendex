import assert from "node:assert/strict";
import test, { after } from "node:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pollChildInbox } from "../extensions/subagent/child-inbox.js";
import { inboxDir, processingDir, taskRegistryPath } from "../extensions/subagent/paths.js";
import { cleanupTempRuntimes, importRuntimeCopy, tempRuntime } from "./browser-fixture.js";

after(cleanupTempRuntimes);

async function registryFailure(poll: typeof pollChildInbox): Promise<void> {
	const root = tempRuntime();
	mkdirSync(inboxDir(root, "engineer"), { recursive: true });
	const source = join(inboxDir(root, "engineer"), "work.md");
	writeFileSync(source, "inspect the code");
	// A blocked registry target makes the real atomic replacement fail after claim.
	mkdirSync(taskRegistryPath(root));
	let owner: string | undefined;
	let delivered = false;
	const pi = { sendUserMessage() { delivered = true; }, events: { emit() {} } } as unknown as Parameters<typeof poll>[2];
	const ctx = { ui: { setStatus() {} }, sessionManager: { getSessionFile() {} } } as unknown as Parameters<typeof poll>[3];
	const unhandled: unknown[] = [];
	const rejection = (error: unknown) => { unhandled.push(error); };
	process.on("unhandledRejection", rejection);
	try {
		await assert.rejects(poll(root, "engineer", pi, ctx, (file) => { owner = file; }, (file) => { if (owner === file) owner = undefined; }));
		await new Promise(setImmediate);
		assert.equal(readFileSync(source, "utf8"), "inspect the code", "a registry failure after claim must restore the inbox");
		assert.equal(existsSync(join(processingDir(root, "engineer"), "work.md")), false);
		assert.equal(owner, undefined);
		assert.equal(delivered, false);
		assert.deepEqual(unhandled, []);
	} finally {
		process.off("unhandledRejection", rejection);
	}
}

test("whole inbox poll restores a post-claim registry failure and rejects without an unhandled rejection", async () => {
	await registryFailure(pollChildInbox);
	const mutant = await importRuntimeCopy("child-inbox.ts", "await recordTaskDispatchFailure(runtimeRoot, path.basename(paths.processing, \".md\"), paths, String(error));", "void recordTaskDispatchFailure;") as typeof import("../extensions/subagent/child-inbox.js");
	await assert.rejects(registryFailure(mutant.pollChildInbox), /ENOENT/);
});
