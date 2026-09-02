import { basename } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { pinSessionModel } from "./model.js";
import { openManager } from "./overlay.js";
import { recordProjectTrust, samePath } from "./paths.js";
import { configuredShortcut, settingBoolean } from "./settings.js";
import { INSTALL_SYMBOL, type SessionAction, type SessionManagerContext } from "./types.js";

const pendingSessionManagerActions = new Map<string, SessionAction>();
let pendingSessionManagerActionCounter = 0;

function queueSessionManagerCommandAction(ctx: SessionManagerContext, action: SessionAction): void {
	if (action.type !== "resume") return;
	const id = `sm-${Date.now().toString(36)}-${(++pendingSessionManagerActionCounter).toString(36)}`;
	pendingSessionManagerActions.set(id, action);
	ctx.ui.setEditorText(`/sessions:resume-pending ${id}`);
	ctx.ui.notify(`${action.title || basename(action.path)} — press enter to resume`, "info");
}

async function runSessionManagerAction(ctx: SessionManagerContext, pi: ExtensionAPI, action: SessionAction): Promise<boolean> {
	if (action.type !== "resume") return true;
	const switchSession = (ctx as { switchSession?: ExtensionCommandContext["switchSession"] }).switchSession;
	if (typeof switchSession !== "function") return false;
	if (samePath(action.path, ctx.sessionManager.getSessionFile())) {
		ctx.ui.notify("Already in this session", "info");
		return true;
	}
	const targetTitle = action.title || basename(action.path);
	const currentModel = action.keepCurrentModel ? ctx.model : undefined;
	const currentThinking = action.keepCurrentModel && typeof pi.getThinkingLevel === "function" ? pi.getThinkingLevel() : undefined;
	if (currentModel) pinSessionModel(action.path, currentModel, currentThinking);
	const result = await switchSession.call(ctx, action.path, {
		withSession: async (replacementCtx) => {
			if (currentModel) replacementCtx.ui.notify(`Using current model: ${currentModel.provider}/${currentModel.id}`, "info");
			replacementCtx.ui.notify(`Resumed ${targetTitle}${currentModel ? " with current model" : ""}`, "info");
		},
	});
	if (result.cancelled) ctx.ui.notify("Session switch cancelled", "info");
	return true;
}

async function handleSessionsCommand(_args: string, ctx: SessionManagerContext, pi: ExtensionAPI): Promise<void> {
	if (!ctx.hasUI) {
		ctx.ui.notify("/sessions requires interactive UI", "error");
		return;
	}
	const waitForIdle = (ctx as { waitForIdle?: () => Promise<void> }).waitForIdle;
	if (typeof waitForIdle === "function") await waitForIdle.call(ctx);
	else if (typeof ctx.isIdle === "function" && !ctx.isIdle()) {
		ctx.ui.notify("Session manager can open after the current turn finishes", "warning");
		return;
	}
	const action = await openManager(ctx, pi);
	if (!(await runSessionManagerAction(ctx, pi, action))) queueSessionManagerCommandAction(ctx, action);
}

export default function sessionManagerExtension(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;

	if (!settingBoolean("enabled", true)) return;

	pi.on("session_start", async (_event, ctx) => {
		recordProjectTrust(ctx);
	});

	pi.registerCommand("sessions", {
		description: "Pi session browser and resume manager.",
		handler: async (args, ctx) => {
			const trimmed = args.trim();
			if (trimmed.startsWith("resume-pending")) {
				const id = trimmed.slice("resume-pending".length).trim();
				const action = pendingSessionManagerActions.get(id);
				if (!action) {
					ctx.ui.notify("No pending session-manager resume action found.", "warning");
					return;
				}
				pendingSessionManagerActions.delete(id);
				if (!(await runSessionManagerAction(ctx, pi, action))) ctx.ui.notify("Session resume is unavailable in this context.", "error");
				return;
			}
			await handleSessionsCommand(args, ctx, pi);
		},
	});
	pi.registerCommand("sessions:resume-pending", {
		description: "Run a pending session-manager resume action",
		handler: async (args, ctx) => {
			const id = args.trim();
			const action = pendingSessionManagerActions.get(id);
			if (!action) {
				ctx.ui.notify("No pending session-manager resume action found.", "warning");
				return;
			}
			pendingSessionManagerActions.delete(id);
			if (!(await runSessionManagerAction(ctx, pi, action))) ctx.ui.notify("Session resume is unavailable in this context.", "error");
		},
	});

	const shortcut = configuredShortcut();
	if (shortcut) {
		pi.registerShortcut(shortcut, {
			description: "Open session manager",
			handler: async (ctx) => handleSessionsCommand("", ctx, pi),
		});
	}
}
