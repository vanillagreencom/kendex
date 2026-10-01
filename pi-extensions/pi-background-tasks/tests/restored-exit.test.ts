import { expect, test } from "bun:test";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";

test("restored exits read their tail before delivery and suppress completions after clear or shutdown", () => {
	const result = runSpawnFixture("restored-exit.ts", {}) as { delivered: number };
	expect(result.delivered).toBe(5);
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: dropping the asynchronous exit tail fails the registered lifecycle suite", () => {
	expect(() => runSpawnFixture("restored-exit.ts", {}, {
		file: "extensions/background-tasks.ts", from: "options, tail) });", to: "options, { text: \"\", truncated: false }) });",
	})).toThrow("spawn_fixture.child_exit=1");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: dropping disk omission information loses exit-tail metadata", () => {
	expect(() => runSpawnFixture("restored-exit.ts", {}, {
		file: "extensions/background-tasks.ts", from: ", output?.truncated)", to: ", false)",
	})).toThrow("exit omission metadata: delivered");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: dropping the forced omission marker loses exit-tail metadata", () => {
	expect(() => runSpawnFixture("restored-exit.ts", {}, {
		file: "extensions/format.ts", from: "if (!truncated && text.length <= maxChars)", to: "if (text.length <= maxChars)",
	})).toThrow("exit omission metadata: delivered");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: forgetting bounded-read omissions loses exit-tail metadata", () => {
	expect(() => runSpawnFixture("restored-exit.ts", {}, {
		file: "extensions/log-tail.ts", from: "truncated: size > read", to: "truncated: false",
	})).toThrow("exit omission metadata: delivered");
}, SPAWN_FIXTURE_TIMEOUT_MS);
