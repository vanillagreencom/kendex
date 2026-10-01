import { expect, jest, test } from "bun:test";
import { rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { QolSessionSearchComponent } from "../extensions/qol/session-search/component.ts";
import * as cache from "../extensions/qol/session-search/cache.ts";
import { searchQolSessionHits } from "../extensions/qol/session-search/search.ts";
import { componentState, filesystemSpies, runtimeCopy, scratch, session, settled, theme } from "./search-fixture.ts";
import { makeCtx } from "./fake-pi.ts";

test("async index streams prompts and resolves a shared project once without sync reads", async () => {
	const root = scratch();
	try {
		const value = session(root);
		writeFileSync(value.path, JSON.stringify({ type: "message", id: "p", message: { role: "user", content: "alpha beta" } }));
		const check = async (runtime: typeof cache) => {
			const spies = filesystemSpies();
			try {
				const values = await runtime.prepareQolSessionSearchSessions([value], new AbortController().signal);
				expect(values[0]?.canonicalCwd).toBe(root);
				expect(values[0]?.userMessages?.[0]?.entryId).toBe("p");
				expect(spies.counts().readSync).toBe(0);
			} finally { spies.restore(); }
		};
		await check(cache);
		await runtimeCopy<typeof cache>("qol/session-search/cache.ts", [
			{ file: "qol/session-search/cache.ts", from: "await forEachSessionJsonlLineAsync(session.path,", to: "forEachSessionJsonlLine(session.path," },
			{ file: "qol/session-search/cache.ts", from: "}, signal);", to: "});" },
		], async (mutant) => { await expect(check(mutant)).rejects.toThrow(); });
	} finally { rmSync(root, { recursive: true, force: true }); }
});

test("shutdown cancels a load and a late result cannot replace the next load", async () => {
	const root = scratch();
	const manager = SessionManager as unknown as {
		list: (cwd: string, directory: string, progress?: unknown, signal?: AbortSignal) => Promise<unknown[]>;
		listAll: (progress?: unknown, signal?: AbortSignal) => Promise<unknown[]>;
	};
	const original = { list: manager.list, listAll: manager.listAll, directory: process.env.PI_CODING_AGENT_SESSION_DIR };
	try {
		const check = async (runtime: typeof cache) => {
			for (const directory of [root, undefined]) {
				if (directory) process.env.PI_CODING_AGENT_SESSION_DIR = directory;
				else delete process.env.PI_CODING_AGENT_SESSION_DIR;
				let finish!: (values: unknown[]) => void;
				let calls = 0;
				let discoveryAborted = false;
				const discover = (signal?: AbortSignal) => {
					calls++;
					if (calls !== 1) return Promise.resolve([]);
					signal?.addEventListener("abort", () => { discoveryAborted = true; }, { once: true });
					return new Promise<unknown[]>((resolve) => { finish = resolve; });
				};
				manager.list = (_cwd, _directory, _progress, signal) => discover(signal);
				manager.listAll = (_progress, signal) => discover(signal);
				const ctx = makeCtx({ cwd: root });
				const pending = runtime.refreshQolSessionSearchCache(ctx as never);
				const outcome = pending.then(() => "published", () => "cancelled");
				try {
					runtime.releaseQolSessionSearchCache();
					expect(discoveryAborted).toBe(true);
					await runtime.refreshQolSessionSearchCache(ctx as never);
					finish([session(root)]);
					expect(await outcome).toBe("cancelled");
					expect(await runtime.refreshQolSessionSearchCache(ctx as never)).toEqual([]);
				} finally { finish([]); await outcome; runtime.releaseQolSessionSearchCache(); }
			}
		};
		await check(cache);
		await runtimeCopy<typeof cache>("qol/session-search/cache.ts", [{ file: "qol/session-search/cache.ts", from: "qolSessionSearchLoadController?.abort();", to: "void qolSessionSearchLoadController;" }], async (mutant) => { await expect(check(mutant)).rejects.toThrow(); mutant.releaseQolSessionSearchCache(); });
		await runtimeCopy<typeof cache>("qol/session-search/cache.ts", [
			{ file: "qol/session-search/cache.ts", from: "SessionManager.list(ctx.cwd, customSessionDir, onProgress, signal)", to: "SessionManager.list(ctx.cwd, customSessionDir, onProgress)" },
			{ file: "qol/session-search/cache.ts", from: "SessionManager.listAll(onProgress, signal)", to: "SessionManager.listAll(onProgress)" },
		], async (mutant) => { await expect(check(mutant)).rejects.toThrow(); });
	} finally {
		manager.list = original.list; manager.listAll = original.listAll;
		if (original.directory === undefined) delete process.env.PI_CODING_AGENT_SESSION_DIR;
		else process.env.PI_CODING_AGENT_SESSION_DIR = original.directory;
		cache.releaseQolSessionSearchCache(); rmSync(root, { recursive: true, force: true });
	}
});

test("scope uses prepared canonical paths, including symlinked projects", async () => {
	const root = scratch();
	try {
		const alias = join(root, "alias");
		symlinkSync(root, alias, "dir");
		const check = async (Component: typeof QolSessionSearchComponent) => {
			const component = new Component(() => {}, { requestRender() {} }, theme as never, { status: "ready", sessions: [session(alias)] }, root);
			try { await settled(component); expect(componentState(component).searchState.total).toBe(1); }
			finally { component.dispose(); }
		};
		await check(QolSessionSearchComponent);
		await runtimeCopy<{ QolSessionSearchComponent: typeof QolSessionSearchComponent }>("qol/session-search/component.ts", [{ file: "qol/session-search/component.ts", from: "session.canonicalCwd === cwd", to: "session.cwd === cwd" }], async (mutant) => { await expect(check(mutant.QolSessionSearchComponent)).rejects.toThrow(); });
	} finally { rmSync(root, { recursive: true, force: true }); }
});

test("typing is debounced and closing cancels the pending query and late index publication", async () => {
	const root = scratch();
	try {
		const check = async (Component: typeof QolSessionSearchComponent) => {
			let renders = 0;
			const component = new Component(() => {}, { requestRender: () => { renders++; } }, theme as never, { status: "ready", sessions: [session(root)] }, root);
			await settled(component);
			jest.useFakeTimers();
			try {
				const previous = componentState(component).queryController;
				for (const char of "alpha") component.handleInput(char);
				expect(componentState(component).queryController).toBe(previous);
				expect(previous?.signal.aborted).toBe(true);
				jest.advanceTimersByTime(19);
				expect(componentState(component).queryController).toBe(previous);
				component.dispose();
				const closedRenders = renders;
				component.setSessions({ status: "failed", error: "late" });
				jest.advanceTimersByTime(100);
				await Promise.resolve();
				expect(renders).toBe(closedRenders);
				expect(componentState(component).searchState.results).toEqual([]);
			} finally { jest.useRealTimers(); component.dispose(); }
		};
		await check(QolSessionSearchComponent);
		for (const patch of [
			{ from: "this.debounceTimer = setTimeout(() => this.updateResults(true), 20);", to: "this.updateResults(true);" },
			{ from: "if (signal.aborted) return;", to: "void signal;", count: 3 },
		]) await runtimeCopy<{ QolSessionSearchComponent: typeof QolSessionSearchComponent }>("qol/session-search/component.ts", [{ file: "qol/session-search/component.ts", ...patch }], async (mutant) => { await expect(check(mutant.QolSessionSearchComponent)).rejects.toThrow(); });
	} finally { rmSync(root, { recursive: true, force: true }); }
});

test("query cancellation stops before matching and preserves prompt ranking and snippet text", async () => {
	const value = { ...session("/missing"), userMessages: [{ index: 1, text: "alpha beta", timestamp: 1 }, { index: 2, text: "alphabet soup", timestamp: 2 }] };
	const check = async (search: typeof searchQolSessionHits) => {
		const aborted = new AbortController(); aborted.abort();
		await expect(search([value], "alpha", "/missing", aborted.signal)).rejects.toThrow();
		const hits = await search([value], '"alpha beta"', "/missing", new AbortController().signal);
		expect(hits.map((hit) => [hit.message.index, hit.snippet])).toEqual([[1, "alpha beta"]]);
	};
	await check(searchQolSessionHits);
	for (const patch of [
		{ from: "signal.throwIfAborted();", to: "void signal;", count: 3 },
		{ from: "return hits.slice(0, limit);", to: "return hits.slice(0, 0);" },
	]) await runtimeCopy<{ searchQolSessionHits: typeof searchQolSessionHits }>("qol/session-search/search.ts", [{ file: "qol/session-search/search.ts", ...patch }], async (mutant) => { await expect(check(mutant.searchQolSessionHits)).rejects.toThrow(); });
});
