import { afterAll, expect, test } from "bun:test";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { testPi } from "./fixtures/exec.ts";

// Keep the real deadline scheduler, with a short deadline in a disposable runtime copy.
const root = join(process.cwd(), "tmp", "manager-action-deadline-tests");
mkdirSync(root, { recursive: true });
cpSync(join(import.meta.dir, "../extensions/manager"), root, { recursive: true });
const path = join(root, "process.ts");
const source = readFileSync(path, "utf8");
const before = "PACKAGE_COMMAND_TIMEOUT_MS = 60_000";
expect(source.split(before).length - 1).toBe(1);
writeFileSync(path, source.replace(before, "PACKAGE_COMMAND_TIMEOUT_MS = 5"));
const { runUninstall, runUpdate } = await import(join(root, "actions.ts"));
const { closeInventorySession } = await import(join(root, "inventory.ts"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

test("every npm and kendex action times out when the host spawn never exits", async () => {
	const item = { id: "package:user:/fixture:example", kind: "package", packageName: "example", scope: "user", packageDir: "/fixture" };
	const rows = [
		{ verb: "update", method: { kind: "kendex", packageName: "example", sourceRepo: "/source", scope: "user", cwd: process.cwd() } },
		{ verb: "uninstall", method: { kind: "kendex", packageName: "example", scope: "user", cwd: process.cwd() } },
		{ verb: "update", method: { kind: "npm", npmName: "example", scope: "user", cwd: process.cwd(), command: "npm", argsPrefix: [] } },
		{ verb: "uninstall", method: { kind: "npm", npmName: "example", scope: "user", cwd: process.cwd(), command: "npm", argsPrefix: [] } },
	] as const;
	for (const row of rows) {
		let deliveredSignal: AbortSignal | undefined;
		const pi = testPi(async (_command, _args, options) => {
			expect(options?.timeout).toBe(5);
			deliveredSignal = options?.signal;
			return new Promise(() => {});
		});
		try {
			const plan = { item, method: row.method };
			const result = await (row.verb === "update" ? runUpdate(pi, plan as never) : runUninstall(pi, plan as never, { settingsFiles: [] } as never));
			expect(result.ok).toBe(false);
			expect(result.message.split("\n")[0]).toBe(`pi-extension-manager: ${row.method.kind}-${row.verb}-timeout=${row.method.kind}`);
			expect(deliveredSignal?.aborted).toBe(true);
		} finally { closeInventorySession(pi); }
	}
});
