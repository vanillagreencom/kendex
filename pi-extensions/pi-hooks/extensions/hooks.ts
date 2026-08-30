import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { isAbsolute, resolve } from "node:path";

import { isBareCd, preCommitGate } from "./bash-guards.js";
import { refusalReason, repoCopyRefusal } from "./repo-copy-guard.js";
import { getBool, getNumber, readConfig, recordProjectTrust } from "./config.js";
import { deliverDrift, runDriftCheck } from "./drift-check.js";
import { workspaceClippyOutcome } from "./lint-hooks.js";

const INSTALL_SYMBOL = Symbol.for("kendex.pi-hooks.installed");

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
	/** Identifies the last clippy run steered to the agent; see the end-of-turn handler. */
	let lastClippyFingerprint: string | undefined;

	pi.on("turn_start", () => {
		turn = freshTurnState();
	});

	// Pi port of hooks/session-drift-check.sh. Fresh starts only: a resumed
	// session already carries the report and a reload re-runs extensions in
	// place. Fire-and-forget — an informational check never gates startup.
	pi.on("session_start", (event, ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		if (event.reason === "reload" || event.reason === "resume") return;
		const cfg = readConfig(ctx.cwd);
		if (!getBool(cfg, "enabled") || !getBool(cfg, "sessionDriftCheck")) return;

		void deliverDrift(
			runDriftCheck(ctx.cwd, {
				timeoutMs: getNumber(cfg, "driftCheckTimeoutMs"),
			}),
			(message) =>
				pi.sendMessage(
					{ customType: "kendex-drift", content: message, display: true },
					{ triggerTurn: false },
				),
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
			const verdict = await preCommitGate(command, ctx.cwd);
			if (verdict.kind === "refuse") {
				return { block: true, reason: verdict.reason };
			}
			// The bash hook writes this to stderr, which the harness shows the
			// person and not the agent; Pi's equivalent is the UI notice.
			if (verdict.notice && ctx.hasUI) ctx.ui.notify(verdict.notice, "info");
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

		// Recorded for the end-of-turn check, which is the only lane that runs
		// clippy. A .rs write costs nothing here.
		turn.rustFilesTouched.add(isAbsolute(filePath) ? filePath : resolve(ctx.cwd, filePath));
		return undefined;
	});

	pi.on("turn_end", async (_event, ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		const cfg = readConfig(ctx.cwd);
		if (!getBool(cfg, "enabled")) return undefined;
		if (!getBool(cfg, "taskCompletedCheck")) return undefined;
		if (turn.rustFilesTouched.size === 0) return undefined;

		const outcome = workspaceClippyOutcome(ctx.cwd, getNumber(cfg, "clippyTimeoutMs"));
		if (outcome.kind === "clean") {
			// A clean turn also forgets the last report, so an error that comes
			// back after a green turn is delivered again rather than suppressed.
			lastClippyFingerprint = undefined;
			return undefined;
		}
		const summary = outcome.kind === "errors"
			? `pi-hooks: clippy reported ${outcome.lines.length} workspace error(s) at turn end:\n${outcome.lines.slice(0, 5).join("\n")}`
			: `pi-hooks: end-of-turn clippy proved nothing about the tree: ${outcome.reason}.`;

		// Pi discards a turn_end handler's return value, and since pi#8022 a
		// `triggerTurn: false` message is recorded without steering, which a
		// headless run that is ending never reads. `triggerTurn: true` steers
		// the active run, so the loop drains it after this event and the agent
		// answers for its own errors in every mode. Repeating an identical run
		// is what that turn could loop on: the agent edits, clippy fails the
		// same way, and the report steers again. Steering only a run that
		// changed bounds it — an agent making no progress is told once.
		//
		// The digest decides that, never the summary: the summary is a count
		// and five header lines, so an edit that moves an error or changes its
		// detail renders identically while the tree really did change. `display:
		// false` leaves interactive rendering to the notification below, which a
		// headless session never sees.
		const fingerprint = outcome.kind === "errors" ? outcome.digest : outcome.reason;
		if (fingerprint !== lastClippyFingerprint) {
			lastClippyFingerprint = fingerprint;
			pi.sendMessage(
				{ customType: "kendex-clippy", content: summary, display: false },
				{ triggerTurn: true },
			);
		}
		if (ctx.hasUI) ctx.ui.notify(summary, outcome.kind === "errors" ? "warning" : "info");
		return undefined;
	});
}
