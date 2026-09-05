// mapWithConcurrencyLimit and the dispatch wrapper over it.

import assert from "node:assert/strict";
import { mapWithConcurrencyLimit } from "../extensions/subagent/dispatch.js";
import test from "node:test";

test("mapWithConcurrencyLimit returns empty array for empty input without invoking fn", async () => {
	let invoked = 0;
	const results = await mapWithConcurrencyLimit<number, number>([], 4, async () => {
		invoked += 1;
		return 0;
	});
	assert.deepEqual(results, []);
	assert.equal(invoked, 0);
});

test("mapWithConcurrencyLimit handles a single item with concurrency > items", async () => {
	let active = 0;
	let maxActive = 0;
	const results = await mapWithConcurrencyLimit([42], 8, async (item) => {
		active += 1;
		maxActive = Math.max(maxActive, active);
		await new Promise((resolve) => setTimeout(resolve, 1));
		active -= 1;
		return item * 2;
	});
	assert.deepEqual(results, [84]);
	assert.equal(maxActive, 1);
});

test("mapWithConcurrencyLimit caps active workers at items.length when items < concurrency", async () => {
	const items = [1, 2, 3];
	let active = 0;
	let maxActive = 0;
	const results = await mapWithConcurrencyLimit(items, 8, async (item) => {
		active += 1;
		maxActive = Math.max(maxActive, active);
		await new Promise((resolve) => setTimeout(resolve, 5));
		active -= 1;
		return item * 2;
	});
	assert.deepEqual(results, [2, 4, 6]);
	assert.equal(maxActive, 3);
});

test("mapWithConcurrencyLimit preserves submission order with items >> concurrency", async () => {
	const items = Array.from({ length: 24 }, (_, index) => index);
	let active = 0;
	let maxActive = 0;
	const results = await mapWithConcurrencyLimit(items, 4, async (item) => {
		active += 1;
		maxActive = Math.max(maxActive, active);
		await new Promise((resolve) => setTimeout(resolve, 1 + (item % 3)));
		active -= 1;
		return item * 2;
	});
	assert.deepEqual(results, items.map((item) => item * 2));
	assert.equal(maxActive, 4);
});

test("mapWithConcurrencyLimit keeps workers saturated across an uneven workload", async () => {
	// Every 4th task takes 5x as long as the others. The old batched
	// dispatch would idle 3 workers for the slow task's tail before the
	// next batch started; the flat pool should keep min(K, remaining)
	// workers active until all tasks complete.
	const items = Array.from({ length: 16 }, (_, index) => index);
	const fastMs = 5;
	const slowMs = 25;
	const concurrency = 4;
	let active = 0;
	let maxActive = 0;
	let started = 0;
	let finished = 0;
	let saturatedSamples = 0;
	let unsaturatedSamples = 0;
	const sampler = setInterval(() => {
		const remaining = items.length - finished;
		const expectedActive = Math.min(concurrency, remaining);
		if (remaining <= concurrency) return; // tail decrescendo is expected
		if (started < items.length && active < expectedActive) unsaturatedSamples += 1;
		else saturatedSamples += 1;
	}, 2);
	const start = Date.now();
	const results = await mapWithConcurrencyLimit(items, concurrency, async (item) => {
		started += 1;
		active += 1;
		maxActive = Math.max(maxActive, active);
		await new Promise((resolve) => setTimeout(resolve, item % 4 === 0 ? slowMs : fastMs));
		active -= 1;
		finished += 1;
		return item;
	});
	clearInterval(sampler);
	const elapsed = Date.now() - start;
	assert.deepEqual(results, items);
	assert.equal(maxActive, concurrency);
	// Flat-pool wall-clock is ~max(slowest_task, totalWork/K). The batched
	// baseline with batchSize=8 idled workers for slow-task tails between
	// batches; the flat pool removes that dead time. Generous bounds keep
	// the assertion stable on slow CI runners.
	const totalWork = items.reduce((sum, item) => sum + (item % 4 === 0 ? slowMs : fastMs), 0);
	const flatLowerBound = totalWork / concurrency;
	assert.ok(elapsed >= flatLowerBound * 0.5, `elapsed ${elapsed}ms below realistic flat-pool floor ${flatLowerBound}ms`);
	assert.ok(saturatedSamples > 0, "expected at least one saturated sample mid-run");
	// While remaining items > concurrency, the pool must stay saturated.
	// Allow a tiny number of races (sampler firing between a task's
	// completion-increment and the worker's next pickup).
	assert.ok(unsaturatedSamples <= 1, `flat pool dropped below concurrency mid-run (${unsaturatedSamples} unsaturated samples, ${saturatedSamples} saturated)`);
});

test("mapWithConcurrencyLimit rejects when the mapper throws (callers must catch)", async () => {
	const items = [0, 1, 2, 3];
	const invoked: number[] = [];
	await assert.rejects(
		mapWithConcurrencyLimit(items, 2, async (item) => {
			invoked.push(item);
			if (item === 1) throw new Error("boom");
			await new Promise((resolve) => setTimeout(resolve, 1));
			return item;
		}),
		/boom/,
	);
	// Helper does not swallow thrown mappers — this is why runParallelDispatch
	// wraps its per-task body in try/catch before handing it to the pool.
	assert.ok(invoked.includes(1), "mapper should have run for the throwing item before rejection");
});

test("dispatch-style try/catch wrapper drains the pool and keeps indexed order on throw", async () => {
	// Mirrors the wrapper pattern in runParallelDispatch: each task body is
	// wrapped in try/catch so a single thrown mapper becomes a failed entry
	// at its index instead of aborting the whole pool.
	const items = Array.from({ length: 8 }, (_, index) => index);
	let active = 0;
	let maxActive = 0;
	let completedAfterThrow = 0;
	const throwingIndex = 2;
	const wrap = async (index: number) => {
		active += 1;
		maxActive = Math.max(maxActive, active);
		try {
			if (index === throwingIndex) throw new Error(`task ${index} exploded`);
			await new Promise((resolve) => setTimeout(resolve, 2));
			if (index > throwingIndex) completedAfterThrow += 1;
			return { kind: "ok" as const, index };
		} catch (error) {
			return { kind: "failed" as const, index, errorMessage: (error as Error).message };
		} finally {
			active -= 1;
		}
	};
	const results = await mapWithConcurrencyLimit(items, 3, (item) => wrap(item));
	assert.deepEqual(results.map((r) => r.index), items, "result order must match submission order");
	assert.equal(maxActive, 3);
	for (const result of results) {
		if (result.index === throwingIndex) {
			assert.equal(result.kind, "failed");
			assert.equal((result as { kind: "failed"; errorMessage: string }).errorMessage, `task ${throwingIndex} exploded`);
		} else {
			assert.equal(result.kind, "ok");
		}
	}
	assert.ok(completedAfterThrow >= items.length - throwingIndex - 1, `every task after index ${throwingIndex} must still complete after a peer throws; saw ${completedAfterThrow}`);
});
