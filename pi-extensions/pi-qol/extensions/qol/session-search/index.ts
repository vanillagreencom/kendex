import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { acquirekendexModalLock } from "../bridges.js";
import { SESSION_SEARCH_CONTEXT_TYPE, SESSION_SEARCH_STATUS_KEY } from "../constants.js";
import { settingNumber } from "../settings.js";
import { stringifyError } from "../util.js";
import {
	getPendingSessionSearchMessage,
	pinSessionModel,
	queueSessionSearchPendingAction,
	refreshQolSessionSearchCache,
	sessionDisplayName,
	setPendingSessionSearchMessage,
} from "./cache.js";
import { QolSessionSearchComponent } from "./component.js";
import {
	buildSessionSearchContextMessageWithLoader,
	injectSessionSearchContext,
} from "./context.js";
import type { QolSessionPaletteAction, QolSessionSearchLoad, QolSessionSearchResult } from "./types.js";

export {
	clearSessionSearchPendingAction,
	refreshQolSessionSearchCache,
	releaseQolSessionSearchCache,
	sessionSearchShortcut,
	takeSessionSearchPendingAction,
} from "./cache.js";
export { renderSessionSearchContextMessage } from "./context.js";

function asCommandContext(ctx: ExtensionContext): (ExtensionContext & Partial<ExtensionCommandContext>) {
	return ctx as ExtensionContext & Partial<ExtensionCommandContext>;
}

function queueSessionSearchCommandAction(ctx: ExtensionContext, action: QolSessionPaletteAction): void {
	const id = queueSessionSearchPendingAction(action);
	ctx.ui.setEditorText(`/search:resume-pending ${id}`);
	ctx.ui.notify(`${sessionDisplayName(action.result!)} — press enter to ${action.type === "fork" ? "fork" : "resume"}`, "info");
}

export async function runSessionSearchResumeOrFork(pi: ExtensionAPI, ctx: ExtensionContext, action: QolSessionPaletteAction): Promise<boolean> {
	if (!action.result || (action.type !== "resume" && action.type !== "fork")) return true;
	const commandCtx = asCommandContext(ctx);
	if (typeof commandCtx.switchSession !== "function") return false;
	const targetTitle = sessionDisplayName(action.result);
	const selectedMessage = action.type === "fork" ? action.message : undefined;
	const currentModel = action.keepCurrentModel ? ctx.model : undefined;
	const currentThinking = action.keepCurrentModel && typeof pi.getThinkingLevel === "function" ? pi.getThinkingLevel() : undefined;
	if (currentModel) pinSessionModel(action.result.path, currentModel, currentThinking);
	let replacementStarted = false;
	try {
		const result = await commandCtx.switchSession(action.result.path, {
			withSession: async (replacementCtx: any) => {
				replacementStarted = true;
				if (currentModel) replacementCtx.ui.notify(`Using current model: ${currentModel.provider}/${currentModel.id}`, "info");
				if (selectedMessage) {
					const manager = replacementCtx.sessionManager as any;
					if (selectedMessage.entryId && selectedMessage.parentId && typeof manager?.branch === "function") manager.branch(selectedMessage.parentId);
					else if (selectedMessage.entryId && selectedMessage.parentId === null && typeof manager?.resetLeaf === "function") manager.resetLeaf();
					replacementCtx.ui.setEditorText(selectedMessage.text);
					const timer = setTimeout(() => {
						replacementCtx.ui.notify(`Forked session: ${targetTitle} at prompt #${selectedMessage.index}. Submit to branch from here.`, "info");
					}, 0);
					timer.unref?.();
					return;
				}
				replacementCtx.ui.notify(`Resumed session: ${targetTitle}${currentModel ? " with current model" : ""}`, "info");
			},
		});
		if (result.cancelled) ctx.ui.notify(selectedMessage ? "Fork cancelled" : "Resume cancelled", "info");
	} catch (error) {
		if (!replacementStarted) ctx.ui.notify(`${selectedMessage ? "Fork" : "Resume"} failed: ${stringifyError(error)}`, "error");
	}
	return true;
}

async function createNewSessionWithSearchContext(pi: ExtensionAPI, ctx: ExtensionContext, result: QolSessionSearchResult, customPrompt?: string): Promise<void> {
	const title = sessionDisplayName(result);
	const message = await buildSessionSearchContextMessageWithLoader(ctx, result, customPrompt, "New + Context");

	const commandCtx = asCommandContext(ctx);
	if (typeof commandCtx.newSession === "function") {
		const parentSession = ctx.sessionManager.getSessionFile?.();
		let replacementStarted = false;
		try {
			const switchResult = await commandCtx.newSession({
				parentSession,
				withSession: async (replacementCtx: any) => {
					replacementStarted = true;
					try {
						if (typeof replacementCtx.sendMessage === "function") {
							await replacementCtx.sendMessage({ customType: SESSION_SEARCH_CONTEXT_TYPE, content: message.content, details: message.details, display: true }, { triggerTurn: false });
						}
						replacementCtx.ui.notify(`New session has context from ${title}`, "info");
					} catch (error) {
						replacementCtx.ui.notify(`New session context import failed: ${stringifyError(error)}`, "error");
					}
				},
			});
			if (switchResult.cancelled) ctx.ui.notify("New session cancelled", "info");
		} catch (error) {
			if (!replacementStarted) throw error;
		}
		return;
	}
	setPendingSessionSearchMessage(message);
	ctx.ui.setEditorText("/new");
	ctx.ui.notify(`${title} — press enter to create a new session with this context`, "info");
}

export async function consumePendingSessionSearchContext(pi: ExtensionAPI, ctx: ExtensionContext, reason: unknown): Promise<void> {
	if (reason !== "new") return;
	const pending = getPendingSessionSearchMessage();
	if (!pending) return;
	setPendingSessionSearchMessage(undefined);
	pi.sendMessage({ customType: SESSION_SEARCH_CONTEXT_TYPE, content: pending.content, details: pending.details, display: true }, { triggerTurn: false });
	if (ctx.hasUI) ctx.ui.notify("Imported session-search context.", "info");
}

export async function openQolSessionSearch(pi: ExtensionAPI, ctx: ExtensionContext, initialQuery = ""): Promise<void> {
	if (!ctx.hasUI) {
		ctx.ui.notify("Session search requires interactive UI", "warning");
		return;
	}
	// The overlay opens at once and fills in when the index is loaded: a
	// released index takes a full read of every session file to load again.
	const loading: Promise<QolSessionSearchLoad> = refreshQolSessionSearchCache(ctx).then(
		(sessions) => ({ status: "ready", sessions }),
		(error) => ({ status: "failed", error: stringifyError(error) }),
	);
	const releaseModalLock = acquirekendexModalLock();
	let action: QolSessionPaletteAction | undefined;
	try {
		const currentModel = ctx.model ? { provider: ctx.model.provider, id: ctx.model.id } : undefined;
		action = await ctx.ui.custom<QolSessionPaletteAction>((tui, theme, _keybindings, done) => {
			const component = new QolSessionSearchComponent(done, tui, theme, { status: "loading" }, ctx.cwd, initialQuery, currentModel);
			void loading.then((load) => component.setSessions(load));
			return component;
		}, {
			overlay: true,
			overlayOptions: {
				anchor: "center",
				width: Math.max(70, Math.floor(settingNumber("sessionSearch.overlayWidth", 104, ctx.cwd))),
				maxHeight: "90%",
			},
		});
	} finally {
		releaseModalLock();
	}
	if (!action || action.type === "cancel" || !action.result) return;
	if (action.type === "resume" || action.type === "fork") {
		if (!(await runSessionSearchResumeOrFork(pi, ctx, action))) queueSessionSearchCommandAction(ctx, action);
		return;
	}
	if (action.type === "copy") {
		const text = action.message?.text || action.result.firstMessage;
		ctx.ui.setEditorText(text);
		ctx.ui.notify("Copied selected prompt into the editor", "info");
		return;
	}
	if (action.type === "summarize") {
		try {
			await injectSessionSearchContext(pi, ctx, action.result, action.customPrompt);
		} catch (error) {
			const message = stringifyError(error);
			ctx.ui.notify(/cancelled/i.test(message) ? "Inject + Context cancelled" : `Inject + Context failed: ${message}`, /cancelled/i.test(message) ? "info" : "error");
			ctx.ui.setStatus(SESSION_SEARCH_STATUS_KEY, undefined);
		}
		return;
	}
	if (action.type === "newSession") {
		try {
			await createNewSessionWithSearchContext(pi, ctx, action.result, action.customPrompt);
		} catch (error) {
			const message = stringifyError(error);
			ctx.ui.notify(/cancelled/i.test(message) ? "New + Context cancelled" : `New + Context failed: ${message}`, /cancelled/i.test(message) ? "info" : "error");
			ctx.ui.setStatus(SESSION_SEARCH_STATUS_KEY, undefined);
		}
	}
}
