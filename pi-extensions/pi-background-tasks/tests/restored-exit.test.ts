import { expect, test } from "bun:test";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";

test("restored exits read their tail before delivery and suppress completions after clear or shutdown", () => {
	const result = runSpawnFixture("spawn-extension.ts", { mode: "restored-exit" }) as { delivered: number };
	expect(result.delivered).toBe(5);
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: dropping the asynchronous exit tail fails the registered lifecycle suite", () => {
	expect(() => runSpawnFixture("spawn-extension.ts", { mode: "restored-exit" }, {
		file: "extensions/background-tasks.ts", from: "options, tail) });", to: "options, { text: \"\", truncated: false }) });",
	})).toThrow("spawn_fixture.child_exit=1");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: dropping disk omission information loses exit-tail metadata", () => {
	expect(() => runSpawnFixture("spawn-extension.ts", { mode: "restored-exit" }, {
		file: "extensions/background-tasks.ts", from: ", output?.truncated)", to: ", false)",
	})).toThrow("exit omission metadata: delivered");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: dropping the forced omission marker loses exit-tail metadata", () => {
	expect(() => runSpawnFixture("spawn-extension.ts", { mode: "restored-exit" }, {
		file: "extensions/format.ts", from: "if (!truncated && text.length <= maxChars)", to: "if (text.length <= maxChars)",
	})).toThrow("exit omission metadata: delivered");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: forgetting bounded-read omissions loses exit-tail metadata", () => {
	expect(() => runSpawnFixture("spawn-extension.ts", { mode: "restored-exit" }, {
		file: "extensions/log-tail.ts", from: "truncated: size > read || decoded.length > lengthLimit", to: "truncated: false",
	})).toThrow("exit omission metadata: delivered");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("registered live, orphan and replay exits share admission and retain delivery and suppression", () => {
	const rows = [
		{ producer: "replay", action: "delivered", acquired: 64, delivered: 64, retained: 50 },
		{ producer: "live", action: "delivered", acquired: 64, delivered: 64, retained: 50 },
		{ producer: "orphan", action: "delivered", acquired: 64, delivered: 64, retained: 50 },
		{ producer: "mixed", action: "delivered", acquired: 66, delivered: 65, retained: 50 },
		{ producer: "replay", action: "clear", acquired: 4, delivered: 0, retained: 0 },
		{ producer: "replay", action: "shutdown", acquired: 4, delivered: 0, retained: 64 },
		{ producer: "replay", action: "replacement", acquired: 4, delivered: 0, retained: 64 },
	];
	expect.assertions(rows.length);
	for (const { producer, ...row } of rows) {
		expect(runSpawnFixture("spawn-extension.ts", { mode: "exit-reads", producer, action: row.action }), `${producer}: ${row.action}`).toEqual({ ...row, produced: 64, initial: 4, peak: 4 });
	}
}, SPAWN_FIXTURE_TIMEOUT_MS * 7);

test("must-fail: unprotected queued exits fail the producer-created retention check", () => {
	expect(() => runSpawnFixture("spawn-extension.ts", { mode: "exit-reads", producer: "replay", action: "delivered" }, {
		file: "extensions/background-tasks.ts", from: "if (exitWakeDue.has(task)) return false;\n\t\t\texitWakeDue.add(task);", to: "if (exitWakeDue.has(task)) return false;\n\t\t\tvoid task;",
	})).toThrow("queued exits must remain protected");
}, SPAWN_FIXTURE_TIMEOUT_MS);
