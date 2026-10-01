import { expect, spyOn, test } from "bun:test";
import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import * as tuiRuntime from "@earendil-works/pi-tui";
import * as actions from "../extensions/qol/session-search/index.ts";
import { releaseQolSessionSearchCache } from "../extensions/qol/session-search/cache.ts";
import { makeCtx, makeFakeApi } from "./fake-pi.ts";
import { componentState, filesystemSpies, runtimeCopy, scratch, session, settled, theme } from "./search-fixture.ts";

test("Copy and Fork load the complete selected prompt through shortcuts and menus", async () => {
	const root = scratch();
	const manager = SessionManager as unknown as { listAll: () => Promise<unknown[]> };
	const original = manager.listAll;
	const keys = spyOn(tuiRuntime, "matchesKey").mockImplementation((data, key) => data === key);
	try {
		const value = session(root);
		const text = `TARGET ${"a".repeat(40_000)}\nfinal instruction`;
		// Pi's documented message-entry format includes IDs for action selection.
		writeFileSync(value.path, [
			{ type: "message", id: "first", parentId: null, message: { role: "user", content: "decoy" } },
			{ type: "message", id: "selected", parentId: "first", message: { role: "user", content: text } },
		].map((entry) => JSON.stringify(entry)).join("\n"));
		manager.listAll = async () => [value];
		const check = async (runtime: typeof actions) => {
			for (const row of [
				{ type: "copy", keys: ["alt+c"] },
				{ type: "copy", keys: ["enter", "alt+c"] },
				{ type: "copy", keys: ["enter", "enter", "alt+c"] },
				{ type: "fork", keys: ["alt+f", "enter"] },
				{ type: "fork", keys: ["enter", "alt+f", "enter"] },
				{ type: "fork", keys: ["enter", "enter", "alt+f", "enter"] },
			]) {
				runtime.releaseQolSessionSearchCache();
				let editor = "";
				const branches: string[] = [];
				const failures: string[] = [];
				const spies = filesystemSpies();
				const ctx = makeCtx({
					cwd: root, hasUI: true,
					ui: {
						...makeCtx().ui,
						setEditorText: (draft: string) => { editor = draft; },
						notify: (message: string, level: string) => { if (level === "error") failures.push(message); },
						custom: async (factory: (tui: unknown, theme: unknown, keybindings: unknown, done: (action: unknown) => void) => unknown) => {
							let selected: unknown;
							const component = factory({ requestRender() {} }, theme, undefined, (action) => { selected = action; }) as import("../extensions/qol/session-search/component.ts").QolSessionSearchComponent;
							try {
								await settled(component);
								expect(componentState(component).searchState.results[0]?.message.entryId).toBe("selected");
								expect(componentState(component).searchState.results[0]?.message.text.length).toBeLessThan(40_000);
								row.keys.forEach((key) => component.handleInput(key));
								expect(selected).toBeDefined();
								return selected;
							} finally { component.dispose(); }
						},
					},
					switchSession: async (path: string, options: { withSession: (ctx: unknown) => Promise<void> }) => {
						expect(path).toBe(value.path);
						await options.withSession({ ui: ctx.ui, sessionManager: { branch: (id: string) => { branches.push(id); } } });
						return { cancelled: false };
					},
				});
				try {
					await runtime.openQolSessionSearch(makeFakeApi().api, ctx as never, "TARGET");
					expect(failures).toEqual([]);
					expect(editor).toBe(text);
					expect(branches).toEqual(row.type === "fork" ? ["first"] : []);
					expect(spies.counts().readSync).toBe(0);
					expect(spies.counts().wholeLogReadFileSync).toBe(0);
				} finally { spies.restore(); runtime.releaseQolSessionSearchCache(); }
			}
		};
		await check(actions);
		for (const patch of [
			{ file: "qol/session-search/index.ts", from: "await sessionUserMessageForAction(action.result, action.message, ctx.signal)", to: "action.message", count: 2 },
			{ file: "qol/session-search/cache.ts", from: "const text = fullText ? content : oneLine(content);", to: "const text = oneLine(content);" },
		]) await runtimeCopy<typeof actions>("qol/session-search/index.ts", [patch], async (mutant) => { await expect(check(mutant)).rejects.toThrow(); });
	} finally { keys.mockRestore(); manager.listAll = original; releaseQolSessionSearchCache(); rmSync(root, { recursive: true, force: true }); }
});
