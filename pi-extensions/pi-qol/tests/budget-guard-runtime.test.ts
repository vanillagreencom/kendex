import { expect, test } from "bun:test";
import { QOL_BUDGET_GUARD_SENTINEL, type BudgetTrigger } from "../extensions/qol/budget-guard.ts";
import { BudgetGuardDriver, type DispatchOutcome, type GuardCompactOptions, type GuardLevel } from "../extensions/qol/budget-guard-runtime.ts";

function trigger(key: string, reason: string): BudgetTrigger {
	return { contextWindow: 200_000, key, percent: 90, reason, tokens: 180_000 };
}

interface NotifyCall { message: string; level: GuardLevel }

function recorder() {
	const notifyCalls: NotifyCall[] = [];
	const compactCalls: GuardCompactOptions[] = [];
	const statusCalls: Array<string | undefined> = [];
	const notify = (message: string, level: GuardLevel) => { notifyCalls.push({ level, message }); };
	const onStatus = (message: string | undefined) => { statusCalls.push(message); };
	const makeCompact = (mode: "success" | "fail" | "throw" | "swallow") => {
		return (options: GuardCompactOptions) => {
			compactCalls.push(options);
			if (mode === "throw") throw new Error("dispatch failed");
			if (mode === "swallow") return; // simulate ctx.compact accepting then never calling callbacks
			if (mode === "success") setTimeout(() => options.onComplete?.(), 0);
			if (mode === "fail") setTimeout(() => options.onError?.(new Error("model down")), 0);
		};
	};
	return { compactCalls, makeCompact, notify, notifyCalls, onStatus, statusCalls };
}

test("dispatch fires once per crossing key", () => {
	const driver = new BudgetGuardDriver();
	const { compactCalls, makeCompact, notify, notifyCalls } = recorder();
	const t = trigger("percent:85:1", "90% context >= 85% budget guard");
	const first = driver.dispatch({ compact: makeCompact("swallow"), notify, trigger: t });
	expect((first as Extract<DispatchOutcome, { kind: "dispatched" }>).kind).toBe("dispatched");
	expect(compactCalls.length).toBe(1);
	expect(driver.currentKey).toBe(t.key);
	expect(notifyCalls[0]?.message).toContain("starting compaction");
	const second = driver.dispatch({ compact: makeCompact("swallow"), notify, trigger: t });
	// Same crossing key while compaction is still in-flight - should be deduped.
	expect(second.kind).toBe("in-flight");
});

test("dispatch deduplicates a repeated trigger after completion within the same bucket", async () => {
	const driver = new BudgetGuardDriver();
	const { compactCalls, makeCompact, notify } = recorder();
	const t = trigger("percent:85:1", "reason");
	driver.dispatch({ compact: makeCompact("success"), notify, trigger: t });
	await new Promise((resolve) => setTimeout(resolve, 5));
	expect(driver.canFire).toBe(true);
	const repeat = driver.dispatch({ compact: makeCompact("success"), notify, trigger: t });
	expect(repeat.kind).toBe("dedup");
	expect(compactCalls.length).toBe(1);
});

test("session_compact satisfies the current crossing key", async () => {
	const driver = new BudgetGuardDriver();
	const { compactCalls, makeCompact, notify } = recorder();
	const t = trigger("percent:85:1", "reason");
	driver.dispatch({ compact: makeCompact("success"), notify, trigger: t });
	await new Promise((resolve) => setTimeout(resolve, 5));
	driver.noteSessionCompacted();
	expect(driver.currentKey).toBe(t.key);
	const next = driver.dispatch({ compact: makeCompact("success"), notify, trigger: t });
	expect(next.kind).toBe("dedup");
	expect(compactCalls.length).toBe(1);
});

test("session_compact clears suppression after usage falls below the trigger", async () => {
	const driver = new BudgetGuardDriver();
	const { compactCalls, makeCompact, notify } = recorder();
	const t = trigger("percent:85:1", "reason");
	driver.dispatch({ compact: makeCompact("success"), notify, trigger: t });
	await new Promise((resolve) => setTimeout(resolve, 5));
	driver.noteSessionCompacted();
	expect(driver.dispatch({ compact: makeCompact("success"), notify, trigger: undefined }).kind).toBe("no-trigger");
	expect(driver.dispatch({ compact: makeCompact("success"), notify, trigger: t }).kind).toBe("dispatched");
	expect(compactCalls.length).toBe(2);
});

test("session_compact allows a genuinely new trigger key", async () => {
	const driver = new BudgetGuardDriver();
	const { compactCalls, makeCompact, notify } = recorder();
	const first = trigger("percent:85:1", "first bucket");
	const second = trigger("percent:85:2", "second bucket");
	driver.dispatch({ compact: makeCompact("success"), notify, trigger: first });
	await new Promise((resolve) => setTimeout(resolve, 5));
	driver.noteSessionCompacted();
	expect(driver.dispatch({ compact: makeCompact("success"), notify, trigger: second }).kind).toBe("dispatched");
	expect(compactCalls.length).toBe(2);
});

test("Already compacted is benign only after a later session_compact", async () => {
	const driver = new BudgetGuardDriver();
	const { compactCalls, notify, notifyCalls, onStatus, statusCalls } = recorder();
	const t = trigger("percent:85:1", "reason");
	driver.dispatch({
		compact: (options) => compactCalls.push(options),
		notify,
		onStatus,
		trigger: t,
	});
	driver.noteSessionCompacted();
	compactCalls[0]?.onError?.(new Error("Already compacted"));
	await new Promise((resolve) => setTimeout(resolve, 0));
	expect(driver.currentKey).toBe(t.key);
	expect(driver.canFire).toBe(true);
	expect(statusCalls.at(-1)).toBeUndefined();
	expect(notifyCalls.some((call) => call.level === "error")).toBe(false);
	expect(driver.dispatch({ compact: () => {}, notify, trigger: t }).kind).toBe("dedup");
});

test("Already compacted remains an error without a later session_compact", async () => {
	const driver = new BudgetGuardDriver();
	const { notify, notifyCalls } = recorder();
	driver.dispatch({
		compact: (options) => setTimeout(() => options.onError?.(new Error("Already compacted")), 0),
		notify,
		trigger: trigger("percent:85:1", "reason"),
	});
	await new Promise((resolve) => setTimeout(resolve, 5));
	expect(driver.currentKey).toBeUndefined();
	expect(notifyCalls.some((call) => call.level === "error" && call.message.includes("Already compacted"))).toBe(true);
});

test("dispatch fires for a new bucket key after the first crossing", () => {
	const driver = new BudgetGuardDriver();
	const { makeCompact, notify } = recorder();
	const first = driver.dispatch({ compact: makeCompact("swallow"), notify, trigger: trigger("percent:85:1", "1x") });
	expect(first.kind).toBe("dispatched");
	// In-flight; subsequent triggers (regardless of key) return in-flight.
	const second = driver.dispatch({ compact: makeCompact("swallow"), notify, trigger: trigger("percent:85:2", "2x") });
	expect(second.kind).toBe("in-flight");
});

test("dispatch with no trigger clears the crossing key", () => {
	const driver = new BudgetGuardDriver();
	const { makeCompact, notify } = recorder();
	driver.dispatch({ compact: makeCompact("success"), notify, trigger: trigger("percent:85:1", "x") });
	driver.noteSessionCompacted();
	driver.dispatch({ compact: makeCompact("success"), notify, trigger: undefined });
	expect(driver.currentKey).toBeUndefined();
});

test("dispatch refuses when ctx.compact is missing and notifies the user", () => {
	const driver = new BudgetGuardDriver();
	const { notify, notifyCalls } = recorder();
	const result = driver.dispatch({ compact: undefined, notify, trigger: trigger("p:85:1", "r") });
	expect(result.kind).toBe("no-compact-fn");
	expect(driver.canFire).toBe(true);
	expect(notifyCalls.some((call) => call.message.includes("ctx.compact is unavailable") && call.level === "warning")).toBe(true);
});

test("dispatch propagates the sentinel in customInstructions", () => {
	const driver = new BudgetGuardDriver();
	const { compactCalls, makeCompact, notify } = recorder();
	driver.dispatch({ compact: makeCompact("swallow"), notify, trigger: trigger("p:85:1", "r") });
	expect(compactCalls[0]?.customInstructions ?? "").toContain(QOL_BUDGET_GUARD_SENTINEL);
});

test("dispatch exposes persistent status until compaction callback finishes", async () => {
	const driver = new BudgetGuardDriver();
	const { makeCompact, notify, onStatus, statusCalls } = recorder();
	driver.dispatch({ compact: makeCompact("success"), notify, onStatus, trigger: trigger("p:85:1", "90% context >= 85% budget guard") });
	expect(statusCalls[0]).toContain("QOL budget guard compacting session");
	await new Promise((resolve) => setTimeout(resolve, 5));
	expect(statusCalls.at(-1)).toBeUndefined();
});

test("dispatch clears persistent status on async compact failure", async () => {
	const driver = new BudgetGuardDriver();
	const { makeCompact, notify, onStatus, statusCalls } = recorder();
	driver.dispatch({ compact: makeCompact("fail"), notify, onStatus, trigger: trigger("p:85:1", "r") });
	expect(statusCalls[0]).toContain("QOL budget guard compacting session");
	await new Promise((resolve) => setTimeout(resolve, 5));
	expect(statusCalls.at(-1)).toBeUndefined();
});

test("dispatch clears state and notifies on synchronous compact throw", () => {
	const driver = new BudgetGuardDriver();
	const { notify, notifyCalls, onStatus, statusCalls } = recorder();
	const result = driver.dispatch({ compact: () => { throw new Error("boom"); }, notify, onStatus, trigger: trigger("p:85:1", "r") });
	expect(result.kind).toBe("dispatch-threw");
	expect(driver.canFire).toBe(true);
	// On throw, the crossing key is cleared so the next agent_end can retry.
	expect(driver.currentKey).toBeUndefined();
	expect(statusCalls.at(-1)).toBeUndefined();
	expect(notifyCalls.some((call) => call.message.includes("failed to start") && call.level === "error")).toBe(true);
});

test("dispatch onError clears the crossing key so the next agent_end retries", async () => {
	const driver = new BudgetGuardDriver();
	const { notify, notifyCalls } = recorder();
	const compact = (options: GuardCompactOptions) => {
		setTimeout(() => options.onError?.(new Error("model down")), 0);
	};
	driver.dispatch({ compact, notify, trigger: trigger("p:85:1", "r") });
	await new Promise((resolve) => setTimeout(resolve, 5));
	expect(driver.canFire).toBe(true);
	expect(driver.currentKey).toBeUndefined();
	expect(notifyCalls.some((call) => call.message.includes("failed") && call.level === "error")).toBe(true);
});

test("dispatch respects a stale-context callback by ignoring the call", () => {
	const driver = new BudgetGuardDriver();
	const { compactCalls, makeCompact, notify } = recorder();
	const result = driver.dispatch({ compact: makeCompact("swallow"), notify, staleCtx: () => true, trigger: trigger("p:85:1", "r") });
	expect(result.kind).toBe("ignored");
	expect(compactCalls.length).toBe(0);
});

test("reset clears in-flight and key state", () => {
	const driver = new BudgetGuardDriver();
	const { makeCompact, notify } = recorder();
	driver.dispatch({ compact: makeCompact("swallow"), notify, trigger: trigger("p:85:1", "r") });
	expect(driver.canFire).toBe(false);
	driver.reset();
	expect(driver.canFire).toBe(true);
	expect(driver.currentKey).toBeUndefined();
});
