import { expect, test } from "bun:test";
import { QOL_BUDGET_GUARD_SENTINEL, type BudgetTrigger } from "../extensions/qol/budget-guard.ts";
import {
	BudgetGuardDriver,
	type DispatchOutcome,
	type GuardCompactOptions,
	type GuardDispatchResult,
	type GuardLevel,
	type GuardPendingDispatchInput,
} from "../extensions/qol/budget-guard-runtime.ts";

function trigger(key: string, reason: string): BudgetTrigger {
	return { contextWindow: 200_000, key, percent: 90, reason, tokens: 180_000 };
}

interface NotifyCall { message: string; level: GuardLevel }

interface TestDispatchInput extends GuardPendingDispatchInput {
	trigger: BudgetTrigger | undefined;
}

function dispatchLifecycle(driver: BudgetGuardDriver, input: TestDispatchInput): GuardDispatchResult {
	const staged = driver.stage(input.trigger, input.staleCtx);
	if (staged.kind !== "staged") return { completion: Promise.resolve(), outcome: staged };
	return driver.dispatchPending({
		compact: input.compact,
		notify: input.notify,
		onStatus: input.onStatus,
		staleCtx: input.staleCtx,
	});
}

function dispatch(driver: BudgetGuardDriver, input: TestDispatchInput): DispatchOutcome {
	return dispatchLifecycle(driver, input).outcome;
}

function recorder() {
	const notifyCalls: NotifyCall[] = [];
	const compactCalls: GuardCompactOptions[] = [];
	const statusCalls: Array<string | undefined> = [];
	const notify = (message: string, level: GuardLevel) => { notifyCalls.push({ level, message }); };
	const onStatus = (message: string | undefined) => { statusCalls.push(message); };
	const compact = (options: GuardCompactOptions) => { compactCalls.push(options); };
	const complete = (index = 0) => {
		const callback = compactCalls[index]?.onComplete;
		if (!callback) throw new Error(`Missing compaction completion callback at ${index}`);
		callback();
	};
	const fail = (message: string, index = 0) => {
		const callback = compactCalls[index]?.onError;
		if (!callback) throw new Error(`Missing compaction error callback at ${index}`);
		callback(new Error(message));
	};
	return { compactCalls, complete, fail, compact, notify, notifyCalls, onStatus, statusCalls };
}

const lifecycleRows = [
	{
		name: "dispatch fires once per crossing key",
		expected: {
			firstOutcome: "dispatched",
			compactCalls: 1,
			currentKey: "percent:85:1",
			startingNotification: true,
			repeatOutcome: "in-flight",
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { compactCalls, compact, notify, notifyCalls } = recorder();
			const t = trigger("percent:85:1", "90% context >= 85% budget guard");
			const first = dispatch(driver, { compact, notify, trigger: t });
			observed.firstOutcome = first.kind;
			observed.compactCalls = compactCalls.length;
			observed.currentKey = driver.currentKey;
			observed.startingNotification = (notifyCalls[0]?.message)?.includes("starting compaction");
			const second = dispatch(driver, { compact, notify, trigger: t });
			// Same crossing key while compaction is still in-flight - should be deduped.
			observed.repeatOutcome = second.kind;
			return observed;
		},
	},
	{
		name: "dispatch deduplicates a repeated trigger after completion within the same bucket",
		expected: {
			canFireAfterCompletion: true,
			repeatOutcome: "dedup",
			compactCalls: 1,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { complete, compactCalls, compact, notify } = recorder();
			const t = trigger("percent:85:1", "reason");
			const lifecycle = dispatchLifecycle(driver, { compact, notify, trigger: t });
			complete();
			await lifecycle.completion;
			observed.canFireAfterCompletion = driver.canFire;
			const repeat = dispatch(driver, { compact, notify, trigger: t });
			observed.repeatOutcome = repeat.kind;
			observed.compactCalls = compactCalls.length;
			return observed;
		},
	},
	{
		name: "session_compact satisfies the current crossing key",
		expected: {
			satisfiedKey: "percent:85:1",
			repeatOutcome: "dedup",
			compactCalls: 1,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { complete, compactCalls, compact, notify } = recorder();
			const t = trigger("percent:85:1", "reason");
			const lifecycle = dispatchLifecycle(driver, { compact, notify, trigger: t });
			complete();
			await lifecycle.completion;
			driver.noteSessionCompacted();
			observed.satisfiedKey = driver.currentKey;
			const next = dispatch(driver, { compact, notify, trigger: t });
			observed.repeatOutcome = next.kind;
			observed.compactCalls = compactCalls.length;
			return observed;
		},
	},
	{
		name: "session_compact clears suppression after usage falls below the trigger",
		expected: {
			belowBudgetOutcome: "no-trigger",
			recrossingOutcome: "dispatched",
			compactCalls: 2,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { complete, compactCalls, compact, notify } = recorder();
			const t = trigger("percent:85:1", "reason");
			const lifecycle = dispatchLifecycle(driver, { compact, notify, trigger: t });
			complete();
			await lifecycle.completion;
			driver.noteSessionCompacted();
			observed.belowBudgetOutcome = dispatch(driver, { compact, notify, trigger: undefined }).kind;
			observed.recrossingOutcome = dispatch(driver, { compact, notify, trigger: t }).kind;
			observed.compactCalls = compactCalls.length;
			return observed;
		},
	},
	{
		name: "session_compact allows a genuinely new trigger key",
		expected: {
			newBucketOutcome: "dispatched",
			compactCalls: 2,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { complete, compactCalls, compact, notify } = recorder();
			const first = trigger("percent:85:1", "first bucket");
			const second = trigger("percent:85:2", "second bucket");
			const lifecycle = dispatchLifecycle(driver, { compact, notify, trigger: first });
			complete();
			await lifecycle.completion;
			driver.noteSessionCompacted();
			observed.newBucketOutcome = dispatch(driver, { compact, notify, trigger: second }).kind;
			observed.compactCalls = compactCalls.length;
			return observed;
		},
	},
	{
		name: "Already compacted is benign only after a later session_compact",
		expected: {
			satisfiedKey: "percent:85:1",
			canFire: true,
			finalStatus: undefined,
			errorNotification: false,
			repeatOutcome: "dedup",
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { compactCalls, notify, notifyCalls, onStatus, statusCalls } = recorder();
			const t = trigger("percent:85:1", "reason");
			const lifecycle = dispatchLifecycle(driver, {
				compact: (options) => compactCalls.push(options),
				notify,
				onStatus,
				trigger: t,
			});
			driver.noteSessionCompacted();
			compactCalls[0]?.onError?.(new Error("Already compacted"));
			await lifecycle.completion;
			observed.satisfiedKey = driver.currentKey;
			observed.canFire = driver.canFire;
			observed.finalStatus = statusCalls.at(-1);
			observed.errorNotification = notifyCalls.some((call) => call.level === "error");
			observed.repeatOutcome = dispatch(driver, { compact: () => {}, notify, trigger: t }).kind;
			return observed;
		},
	},
	{
		name: "Already compacted remains an error without a later session_compact",
		expected: {
			currentKey: undefined,
			alreadyCompactedError: true,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { fail, compact, notify, notifyCalls } = recorder();
			const lifecycle = dispatchLifecycle(driver, {
				compact,
				notify,
				trigger: trigger("percent:85:1", "reason"),
			});
			fail("Already compacted");
			await lifecycle.completion;
			observed.currentKey = driver.currentKey;
			observed.alreadyCompactedError = notifyCalls.some((call) => call.level === "error" && call.message.includes("Already compacted"));
			return observed;
		},
	},
	{
		name: "a delayed unrelated error stays visible without clearing a session-satisfied key",
		expected: {
			modelDownError: true,
			satisfiedKey: "percent:85:1",
			repeatOutcome: "dedup",
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { compactCalls, notify, notifyCalls } = recorder();
			const t = trigger("percent:85:1", "reason");
			dispatch(driver, {
				compact: (options) => compactCalls.push(options),
				notify,
				trigger: t,
			});
			driver.noteSessionCompacted();
			compactCalls[0]?.onError?.(new Error("model down"));
			observed.modelDownError = notifyCalls.some((call) => call.level === "error" && call.message.includes("model down"));
			observed.satisfiedKey = driver.currentKey;
			observed.repeatOutcome = dispatch(driver, { compact: () => {}, notify, trigger: t }).kind;
			return observed;
		},
	},
	{
		name: "dispatch refuses a new bucket while the first crossing is in flight",
		expected: {
			firstOutcome: "dispatched",
			newBucketOutcome: "in-flight",
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { compact, notify } = recorder();
			const first = dispatch(driver, { compact, notify, trigger: trigger("percent:85:1", "1x") });
			observed.firstOutcome = first.kind;
			// In-flight; subsequent triggers (regardless of key) return in-flight.
			const second = dispatch(driver, { compact, notify, trigger: trigger("percent:85:2", "2x") });
			observed.newBucketOutcome = second.kind;
			return observed;
		},
	},
	{
		name: "dispatch with no trigger clears the crossing key",
		expected: {
			currentKey: undefined,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { complete, compact, notify } = recorder();
			const lifecycle = dispatchLifecycle(driver, { compact, notify, trigger: trigger("percent:85:1", "x") });
			driver.noteSessionCompacted();
			complete();
			await lifecycle.completion;
			dispatch(driver, { compact, notify, trigger: undefined });
			observed.currentKey = driver.currentKey;
			return observed;
		},
	},
	{
		name: "dispatch refuses when ctx.compact is missing and notifies the user",
		expected: {
			outcome: "no-compact-fn",
			canFire: true,
			unavailableWarning: true,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { notify, notifyCalls } = recorder();
			const result = dispatch(driver, { compact: undefined, notify, trigger: trigger("p:85:1", "r") });
			observed.outcome = result.kind;
			observed.canFire = driver.canFire;
			observed.unavailableWarning = notifyCalls.some((call) => call.message.includes("ctx.compact is unavailable") && call.level === "warning");
			return observed;
		},
	},
	{
		name: "dispatch propagates the sentinel in customInstructions",
		expected: {
			sentinelPresent: true,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { compactCalls, compact, notify } = recorder();
			dispatch(driver, { compact, notify, trigger: trigger("p:85:1", "r") });
			observed.sentinelPresent = (compactCalls[0]?.customInstructions ?? "")?.includes(QOL_BUDGET_GUARD_SENTINEL);
			return observed;
		},
	},
	{
		name: "dispatch exposes persistent status until compaction callback finishes",
		expected: {
			compactingStatus: true,
			finalStatus: undefined,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { complete, compact, notify, onStatus, statusCalls } = recorder();
			const lifecycle = dispatchLifecycle(driver, { compact, notify, onStatus, trigger: trigger("p:85:1", "90% context >= 85% budget guard") });
			observed.compactingStatus = (statusCalls[0])?.includes("QOL budget guard compacting session");
			complete();
			await lifecycle.completion;
			observed.finalStatus = statusCalls.at(-1);
			return observed;
		},
	},
	{
		name: "dispatch clears persistent status on async compact failure",
		expected: {
			compactingStatus: true,
			finalStatus: undefined,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { fail, compact, notify, onStatus, statusCalls } = recorder();
			const lifecycle = dispatchLifecycle(driver, { compact, notify, onStatus, trigger: trigger("p:85:1", "r") });
			observed.compactingStatus = (statusCalls[0])?.includes("QOL budget guard compacting session");
			fail("model down");
			await lifecycle.completion;
			observed.finalStatus = statusCalls.at(-1);
			return observed;
		},
	},
	{
		name: "dispatch clears state and notifies on synchronous compact throw",
		expected: {
			outcome: "dispatch-threw",
			canFire: true,
			currentKey: undefined,
			finalStatus: undefined,
			startError: true,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { notify, notifyCalls, onStatus, statusCalls } = recorder();
			const result = dispatch(driver, { compact: () => { throw new Error("boom"); }, notify, onStatus, trigger: trigger("p:85:1", "r") });
			observed.outcome = result.kind;
			observed.canFire = driver.canFire;
			// On throw, the crossing key is cleared so the next agent_end can retry.
			observed.currentKey = driver.currentKey;
			observed.finalStatus = statusCalls.at(-1);
			observed.startError = notifyCalls.some((call) => call.message.includes("failed to start") && call.level === "error");
			return observed;
		},
	},
	{
		name: "dispatch onError clears the crossing key so the next agent_end retries",
		expected: {
			canFire: true,
			currentKey: undefined,
			failureNotification: true,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { fail, compact, notify, notifyCalls } = recorder();
			const lifecycle = dispatchLifecycle(driver, { compact, notify, trigger: trigger("p:85:1", "r") });
			fail("model down");
			await lifecycle.completion;
			observed.canFire = driver.canFire;
			observed.currentKey = driver.currentKey;
			observed.failureNotification = notifyCalls.some((call) => call.message.includes("failed") && call.level === "error");
			return observed;
		},
	},
	{
		name: "dispatch respects a stale-context callback by ignoring the call",
		expected: {
			outcome: "ignored",
			compactCalls: 0,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { compactCalls, compact, notify } = recorder();
			const result = dispatch(driver, { compact, notify, staleCtx: () => true, trigger: trigger("p:85:1", "r") });
			observed.outcome = result.kind;
			observed.compactCalls = compactCalls.length;
			return observed;
		},
	},
	{
		name: "reset clears in-flight and key state",
		expected: {
			canFireBeforeReset: false,
			canFireAfterReset: true,
			currentKey: undefined,
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const { compact, notify } = recorder();
			dispatch(driver, { compact, notify, trigger: trigger("p:85:1", "r") });
			observed.canFireBeforeReset = driver.canFire;
			driver.reset();
			observed.canFireAfterReset = driver.canFire;
			observed.currentKey = driver.currentKey;
			return observed;
		},
	},
	{
		name: "session_compact from an old reset generation cannot satisfy the current trigger",
		expected: {
			acceptedOldGeneration: false,
			outcome: "dispatched",
			currentKey: "percent:85:b",
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const generationA = driver.reset();
			driver.stage(trigger("percent:85:a", "session A"), undefined, generationA);
			const generationB = driver.reset();
			const current = trigger("percent:85:b", "session B");
			driver.stage(current, undefined, generationB);
			observed.acceptedOldGeneration = driver.noteSessionCompacted(generationA);
			const compactCalls: GuardCompactOptions[] = [];
			const lifecycle = driver.dispatchPending({
				compact: (options) => compactCalls.push(options),
				generation: generationB,
				notify: () => {},
			});
			observed.outcome = lifecycle.outcome.kind;
			observed.currentKey = driver.currentKey;
			compactCalls[0]?.onComplete?.();
			await lifecycle.completion;
			return observed;
		},
	},
	{
		name: "reset invalidates delayed callbacks without mutating the next dispatch",
		expected: {
			completedBeforeCallback: false,
			keyBeforeCallback: "percent:85:2",
			canFireBeforeCallback: false,
			statusBeforeCallback: true,
			completedAfterOldCallbacks: false,
			keyAfterOldCallbacks: "percent:85:2",
			canFireAfterOldCallbacks: false,
			statusAfterOldCallbacks: true,
			oldCallbackNotification: false,
			canFireAfterCompletion: true,
			keyAfterCompletion: "percent:85:2",
		},
		run: async (driver: BudgetGuardDriver) => {
			const observed: Record<string, unknown> = {};
			const compactCalls: GuardCompactOptions[] = [];
			const notifyCalls: NotifyCall[] = [];
			const statusCalls: Array<string | undefined> = [];
			const notify = (message: string, level: GuardLevel) => notifyCalls.push({ level, message });
			const onStatus = (message: string | undefined) => statusCalls.push(message);
			const first = trigger("percent:85:1", "first dispatch");
			const second = trigger("percent:85:2", "second dispatch");
			const firstLifecycle = dispatchLifecycle(driver, {
				compact: (options) => compactCalls.push(options),
				notify,
				onStatus,
				trigger: first,
			});
			driver.reset();
			await firstLifecycle.completion;
			const secondLifecycle = dispatchLifecycle(driver, {
				compact: (options) => compactCalls.push(options),
				notify,
				onStatus,
				trigger: second,
			});
			let secondCompleted = false;
			void secondLifecycle.completion.then(() => { secondCompleted = true; });
			await Promise.resolve();
			observed.completedBeforeCallback = secondCompleted;
			observed.keyBeforeCallback = driver.currentKey;
			observed.canFireBeforeCallback = driver.canFire;
			observed.statusBeforeCallback = (statusCalls.at(-1))?.includes("second dispatch");
		
			compactCalls[0]?.onComplete?.();
			compactCalls[0]?.onError?.(new Error("late first error"));
			await Promise.resolve();
		
			observed.completedAfterOldCallbacks = secondCompleted;
			observed.keyAfterOldCallbacks = driver.currentKey;
			observed.canFireAfterOldCallbacks = driver.canFire;
			observed.statusAfterOldCallbacks = (statusCalls.at(-1))?.includes("second dispatch");
			observed.oldCallbackNotification = notifyCalls.some((call) => call.message.includes("completed") || call.message.includes("late first error"));
		
			compactCalls[1]?.onComplete?.();
			await secondLifecycle.completion;
			observed.canFireAfterCompletion = driver.canFire;
			observed.keyAfterCompletion = driver.currentKey;
			return observed;
		},
	},
];

if (lifecycleRows.length === 0) throw new Error("Budget lifecycle table is empty");

for (const { name, expected, run } of lifecycleRows) {
	test(name, async () => {
		expect.hasAssertions();
		const driver = new BudgetGuardDriver();
		try {
			expect(await run(driver)).toEqual(expected);
		} finally {
			driver.reset();
		}
	});
}
