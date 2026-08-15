import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { isAbsolute, resolve } from "node:path";

import { isBareCd, runPreCommitCheck } from "./bash-guards.js";
import { refusalReason, repoCopyRefusal } from "./repo-copy-guard.js";
import { invalidateClippyCache } from "./cargo.js";
import { getBool, getNumber, readConfig, recordProjectTrust } from "./config.js";
import { driftMessage, runDriftCheck } from "./drift-check.js";
import { clippyIssuesForFile, workspaceClippyErrors } from "./lint-hooks.js";

const INSTALL_SYMBOL = Symbol.for("vstack.pi-hooks.installed");

interface TurnState {
	rustFilesTouched: Set<string>;
}

function freshTurnState(): TurnState {
	return { rustFilesTouched: new Set<string>() };
}

export default function piHooks(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;

	let turn = freshTurnState();

	pi.on("turn_start", () => {
		turn = freshTurnState();
		invalidateClippyCache();
	});

	// Pi port of hooks/session-drift-check.sh. A reload re-runs extensions in
	// a session that already carries the report, so it is the one start
	// reason skipped.
	pi.on("session_start", async (event, ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		if (event.reason === "reload") return;
		const cfg = readConfig(ctx.cwd);
		if (!getBool(cfg, "enabled") || !getBool(cfg, "sessionDriftCheck")) return;

		const result = await runDriftCheck(ctx.cwd, {
			includeAvailable: getBool(cfg, "sessionDriftAvailable"),
			timeoutMs: getNumber(cfg, "driftCheckTimeoutMs"),
		});
		const message = driftMessage(result);
		if (message === undefined) return;
		pi.sendMessage(
			{ customType: "vstack-drift", content: message, display: true },
			{ triggerTurn: false },
		);
	});

	pi.on("tool_call", async (event, ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		const cfg = readConfig(ctx.cwd);
		if (!getBool(cfg, "enabled")) return undefined;
		if (event.toolName !== "bash") return undefined;

		const command = typeof (event.input as { command?: unknown })?.command === "string"
			? (event.input as { command: string }).command
			: "";
		if (!command) return undefined;

		if (getBool(cfg, "blockBareCd") && isBareCd(command)) {
			return {
				block: true,
				reason:
					"Bare 'cd' changes working directory permanently across tool calls. Use a subshell instead: (cd /path && command)",
			};
		}

		if (getBool(cfg, "blockRepoCopy")) {
			const refusal = repoCopyRefusal(command, ctx.cwd);
			if (refusal) {
				return { block: true, reason: refusalReason(command, refusal) };
			}
		}

		if (getBool(cfg, "preCommitCheck")) {
			const timeoutMs = getNumber(cfg, "clippyTimeoutMs");
			const fail = await runPreCommitCheck(ctx.cwd, timeoutMs, command);
			if (fail) {
				return { block: true, reason: fail.reason };
			}
		}

		return undefined;
	});

	pi.on("tool_result", async (event, ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		const cfg = readConfig(ctx.cwd);
		if (!getBool(cfg, "enabled")) return undefined;

		const tool = event.toolName.toLowerCase();
		if (tool !== "edit" && tool !== "write") return undefined;

		const rawPath = (event.input as { path?: unknown })?.path;
		const filePath = typeof rawPath === "string" ? rawPath : "";
		if (!filePath.endsWith(".rs")) return undefined;

		// The working tree changed; drop any cached clippy result from before
		// this edit so the next clippy call reflects the new source state.
		invalidateClippyCache();

		const absolute = isAbsolute(filePath) ? filePath : resolve(ctx.cwd, filePath);
		turn.rustFilesTouched.add(absolute);

		if (!getBool(cfg, "postEditLint")) return undefined;

		const timeoutMs = getNumber(cfg, "clippyTimeoutMs");
		const issues = clippyIssuesForFile(ctx.cwd, absolute, timeoutMs);
		if (issues.length === 0) return undefined;

		const note = `Clippy found ${issues.length} issue(s) in ${filePath}:\n\n${issues.join("\n\n")}`;
		const content = [...(event.content ?? []), { type: "text" as const, text: note }];
		return { content };
	});

	pi.on("turn_end", async (_event, ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		const cfg = readConfig(ctx.cwd);
		if (!getBool(cfg, "enabled")) return undefined;
		if (!getBool(cfg, "taskCompletedCheck")) return undefined;
		if (turn.rustFilesTouched.size === 0) return undefined;

		const timeoutMs = getNumber(cfg, "clippyTimeoutMs");
		// `workspaceClippyErrors` reuses the per-turn clippy cache, so this is
		// free when post-edit-lint already ran and the cache hasn't been
		// invalidated since the last edit.
		const issues = workspaceClippyErrors(ctx.cwd, timeoutMs);
		if (issues.length > 0 && ctx.hasUI) {
			const preview = issues.slice(0, 5).join("\n");
			ctx.ui.notify(
				`pi-hooks: clippy reported ${issues.length} workspace error(s) at turn end:\n${preview}`,
				"warning",
			);
		}
		return undefined;
	});
}
