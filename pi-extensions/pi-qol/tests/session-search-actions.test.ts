import { expect, spyOn, test } from "bun:test";
import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SessionManager, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import * as tuiRuntime from "@earendil-works/pi-tui";
import * as actions from "../extensions/qol/session-search/index.ts";
import * as cache from "../extensions/qol/session-search/cache.ts";
import type { QolSessionSearchComponent } from "../extensions/qol/session-search/component.ts";
import type { QolSessionPaletteAction } from "../extensions/qol/session-search/types.ts";
import { makeCtx, makeFakeApi } from "./fake-pi.ts";
import { componentState, filesystemSpies, runtimeCopy, scratch, session, settled, theme } from "./search-fixture.ts";

test("Copy and Fork own delayed complete prompts across shortcuts, menus and pending commands", async () => {
	const root = scratch(), value = session(root), text = `TARGET ${"a".repeat(40_000)}\nfinal instruction`;
	const manager = SessionManager as unknown as { listAll: () => Promise<unknown[]> }, original = manager.listAll;
	const keys = spyOn(tuiRuntime, "matchesKey").mockImplementation((data, key) => data === key);
	writeFileSync(value.path, ["decoy", text].map((content, i) => JSON.stringify({ type: "message", id: i ? "selected" : "first", parentId: i ? "first" : null, message: { role: "user", content } })).join("\n"));
	manager.listAll = async () => [value];
	const check = async (runtime: typeof actions, payloads = cache) => {
		for (const menu of [[], ["enter"], ["enter", "enter"]]) for (const type of ["copy", "fork", "pendingFork"]) for (const mode of ["unchanged", "overlap", "cancel", "failed"]) {
			runtime.releaseQolSessionSearchCache();
			let editor = "existing draft", copied = "", overlay: QolSessionSearchComponent | undefined, reads = 0, signal: AbortSignal | undefined;
			const branches: string[] = [], spies = filesystemSpies(), originalRead = payloads.sessionUserMessageForAction;
			const input = (data: string) => { if (overlay) overlay.handleInput(data); else editor += data; };
			const read = spyOn(payloads, "sessionUserMessageForAction").mockImplementation(async (...args: Parameters<typeof originalRead>) => {
				reads++; signal = args[2];
				// Delay the real read by one microtask so input overlaps retrieval.
				await Promise.resolve(); input(mode === "cancel" ? "escape" : "new unsent draft");
				expect(editor).toBe("existing draft");
				if (mode === "failed") throw new Error("ACTION_READ_FAILED"); return originalRead(...args);
			});
			const switchSession = async (path: string, options: { withSession: (ctx: unknown) => Promise<void> }) => {
				expect(path).toBe(value.path);
				await options.withSession({ ui: ctx.ui, sessionManager: { branch: (id: string) => branches.push(id) } }); return { cancelled: false };
			};
			const ctx = makeCtx({ cwd: root, hasUI: true, switchSession: type === "pendingFork" ? undefined : switchSession, ui: {
				...makeCtx().ui, setEditorText: (draft: string) => { editor = draft; },
				custom: async (factory: Parameters<ExtensionContext["ui"]["custom"]>[0]) => {
					let finish!: (action: QolSessionPaletteAction) => void;
					const finished = new Promise<QolSessionPaletteAction>((resolve) => { finish = resolve; });
					const requestRender = () => { if (overlay && componentState(overlay).searchStatus?.status === "failed") { expect(overlay.render(100).join("\n")).toContain("ACTION_READ_FAILED"); input("escape"); } };
					overlay = await factory({ requestRender } as never, theme as never, undefined as never, (action) => {
						copied = editor; overlay = undefined; finish(action as QolSessionPaletteAction);
						if (mode === "overlap" && type === "copy") { editor = ""; input("new unsent draft"); }
					}) as QolSessionSearchComponent;
					await settled(overlay);
					expect(componentState(overlay).searchState.results[0]?.message.entryId).toBe("selected");
					[...menu, type === "copy" ? "alt+c" : "alt+f", ...(type === "copy" ? [] : ["enter"])].forEach(input);
					return finished;
				},
			} });
			try {
				await runtime.openQolSessionSearch(makeFakeApi().api, ctx as never, "TARGET");
				if (type === "pendingFork" && (mode === "unchanged" || mode === "overlap")) await runtime.runSessionSearchResumeOrFork(makeFakeApi().api, { ...ctx, switchSession } as never, runtime.takeSessionSearchPendingAction(editor.split(" ")[1]!)!);
				expect({ editor, copied: type === "copy" && mode !== "cancel" && mode !== "failed" ? copied : "", branches, reads, aborted: signal?.aborted, ...spies.counts() }).toEqual({ editor: mode === "cancel" || mode === "failed" ? "existing draft" : type === "copy" && mode === "overlap" ? "new unsent draft" : text, copied: type === "copy" && mode !== "cancel" && mode !== "failed" ? text : "", branches: type !== "copy" && mode !== "cancel" && mode !== "failed" ? ["first"] : [], reads: 1, aborted: true, realpathSync: 0, readSync: 0, wholeLogReadFileSync: 0 });
			} finally { read.mockRestore(); spies.restore(); runtime.releaseQolSessionSearchCache(); }
		}
	};
	try {
		await check(actions);
		for (const patch of [
			{ file: "qol/session-search/cache.ts", from: "const text = fullText ? content : oneLine(content);", to: "const text = oneLine(content);" },
			{ file: "qol/session-search/component.ts", from: "action.result!, action.message, this.indexController.signal", to: "action.result!, action.message" },
			{ file: "qol/session-search/index.ts", from: "\t\t\t\tif (selected.type === \"copy\") {\n\t\t\t\t\tctx.ui.setEditorText(selected.message!.text);\n\t\t\t\t\tctx.ui.notify(\"Copied selected prompt into the editor\", \"info\");\n\t\t\t\t}\n\t\t\t\tdone(selected);", to: "\t\t\t\tdone(selected);\n\t\t\t\tif (selected.type === \"copy\") {\n\t\t\t\t\tctx.ui.setEditorText(selected.message!.text);\n\t\t\t\t\tctx.ui.notify(\"Copied selected prompt into the editor\", \"info\");\n\t\t\t\t}" },
		]) await runtimeCopy<typeof actions>("qol/session-search/index.ts", [patch], async (mutant, copyRoot) => { await expect(check(mutant, await import(join(copyRoot, "extensions/qol/session-search/cache.ts")))).rejects.toThrow(); });
	} finally { keys.mockRestore(); manager.listAll = original; actions.releaseQolSessionSearchCache(); rmSync(root, { recursive: true, force: true }); }
});
