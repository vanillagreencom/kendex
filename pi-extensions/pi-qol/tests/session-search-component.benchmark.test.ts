import { expect, test } from "bun:test";
import { rmSync, writeFileSync } from "node:fs";
import { QolSessionSearchComponent } from "../extensions/qol/session-search/component.ts";
import { releaseQolSessionSearchCache } from "../extensions/qol/session-search/cache.ts";
import { componentState, filesystemSpies, scratch, session, settled, theme } from "./search-fixture.ts";

// This same file runs against an archived main package in the hosted lane.
// It records all steps before asserting, so a failing baseline keeps numbers.
test("component benchmark: 500 sessions, 20 completed keystrokes, bounded hot calls", async () => {
	const root = scratch();
	let component: QolSessionSearchComponent | undefined;
	const spies = filesystemSpies();
	try {
		const sessions = Array.from({ length: 500 }, (_, i) => {
			const value = session(root, i);
			writeFileSync(value.path, JSON.stringify({ type: "message", id: `p${i}`, message: { role: "user", content: "abcdefghijklmnopqrst benchmark prompt" } }));
			return value;
		});
		const start = performance.now();
		component = new QolSessionSearchComponent(() => {}, { requestRender() {} }, theme as never, { status: "ready", sessions }, root);
		await settled(component);
		const coldMs = performance.now() - start;
		const coldCalls = spies.counts();
		spies.clear();
		const steps: Array<{ ms: number; realpathSync: number; readSync: number; wholeLogReadFileSync: number }> = [];
		for (const key of "abcdefghijklmnopqrst") {
			spies.clear();
			const started = performance.now();
			component.handleInput(key);
			await settled(component);
			steps.push({ ms: performance.now() - started, ...spies.counts() });
		}
		console.log(`QOL_COMPONENT_BENCHMARK ${JSON.stringify({ sessions: sessions.length, keys: steps.length, coldMs, coldCalls, maxMs: Math.max(...steps.map((step) => step.ms)), steps })}`);
		expect(steps).toHaveLength(20);
		expect(componentState(component).searchState.results[0]?.message.text).toBe("abcdefghijklmnopqrst benchmark prompt");
		for (const step of steps) {
			expect(step.realpathSync).toBe(0);
			expect(step.readSync).toBe(0);
			expect(step.wholeLogReadFileSync).toBe(0);
			expect(step.ms).toBeLessThan(50);
		}
	} finally {
		component?.dispose?.();
		spies.restore();
		releaseQolSessionSearchCache();
		rmSync(root, { recursive: true, force: true });
	}
});
