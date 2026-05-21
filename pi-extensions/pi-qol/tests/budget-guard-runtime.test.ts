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
	const notify = (message: string, level: GuardLevel) => { notifyCalls.push({ level, message }); };
	const makeCompact = (mode: "success" | "fail" | "throw" | "swallow") => {
		return (options: GuardCompactOptions) => {
			compactCalls.push(options);
			if (mode === "throw") throw new Error("dispatch failed");
			if (mode === "swallow") return; // simulate ctx.compact accepting then never calling callbacks
			if (mode === "success") setTimeout(() => options.onComplete?.(), 0);
			if (mode === "fail") setTimeout(() => options.onError?.(new Error("model down")), 0);
		};
	};
	return { compactCalls, makeCompact, notify, notifyCalls };
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

test("dispatch fires again after session_compact resets the key", async () => {
	const driver = new BudgetGuardDriver();
	const { compactCalls, makeCompact, notify } = recorder();
	const t = trigger("percent:85:1", "reason");
	driver.dispatch({ compact: makeCompact("success"), notify, trigger: t });
	await new Promise((resolve) => setTimeout(resolve, 5));
	driver.noteSessionCompacted();
	expect(driver.currentKey).toBeUndefined();
	const next = driver.dispatch({ compact: makeCompact("success"), notify, trigger: t });
	expect(next.kind).toBe("dispatched");
	expect(compactCalls.length).toBe(2);
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

test("dispatch clears state and notifies on synchronous compact throw", () => {
	const driver = new BudgetGuardDriver();
	const { notify, notifyCalls } = recorder();
	const result = driver.dispatch({ compact: () => { throw new Error("boom"); }, notify, trigger: trigger("p:85:1", "r") });
	expect(result.kind).toBe("dispatch-threw");
	expect(driver.canFire).toBe(true);
	// On throw, the crossing key is cleared so the next agent_end can retry.
	expect(driver.currentKey).toBeUndefined();
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
