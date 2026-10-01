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
		file: "extensions/log-tail.ts", from: "truncated: size > read || decoded.length > lengthLimit", to: "truncated: false",
	})).toThrow("exit omission metadata: delivered");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("clean-shutdown replay bounds acquisition and protects queued exits until delivery or suppression", () => {
	const rows = [
		{ action: "delivered", acquired: 64, delivered: 64, retained: 50 },
		{ action: "clear", acquired: 4, delivered: 0, retained: 0 },
		{ action: "shutdown", acquired: 4, delivered: 0, retained: 64 },
		{ action: "replacement", acquired: 4, delivered: 0, retained: 64 },
	];
	expect.assertions(rows.length);
	for (const row of rows) {
		expect(runSpawnFixture("replay-concurrency.ts", { action: row.action }), row.action).toEqual({ ...row, produced: 64, initial: 4, peak: 4 });
	}
}, SPAWN_FIXTURE_TIMEOUT_MS * 4);

test("must-fail: immediate unbounded replay fails the producer-created acquisition bound", () => {
	expect(() => runSpawnFixture("replay-concurrency.ts", { action: "delivered" }, {
		file: "extensions/lifecycle.ts", from: "mapWithConcurrency(pending, PROBE_CONCURRENCY,", to: "mapWithConcurrency(pending, pending.length,",
	})).toThrow("replay acquisition must be bounded");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: a slot that only schedules delivery fails the producer-created acquisition bound", () => {
	expect(() => runSpawnFixture("replay-concurrency.ts", { action: "delivered" }, {
		file: "extensions/lifecycle.ts", from: "if (!await hooks.sendTaskEvent(\"exit\", task)) return;", to: "if (!hooks.sendTaskEvent(\"exit\", task)) return;",
	})).toThrow("replay acquisition must be bounded");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: unprotected queued exits fail the producer-created retention check", () => {
	expect(() => runSpawnFixture("replay-concurrency.ts", { action: "delivered" }, {
		file: "extensions/background-tasks.ts", from: "protectExit: (task) => { exitWakeDue.add(task); },", to: "protectExit: (task) => { void task; },",
	})).toThrow("queued exits must remain protected");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: queued acquisition without an identity check fails suppression", () => {
	expect(() => runSpawnFixture("replay-concurrency.ts", { action: "replacement" }, {
		file: "extensions/background-tasks.ts",
		from: "if (tasks.get(task.id) !== task || shuttingDown || task.exitNotified) return undefined;\n\t\tconst tail = await",
		to: "const tail = await",
	})).toThrow("suppressed queued tasks must not acquire a log");
}, SPAWN_FIXTURE_TIMEOUT_MS);
