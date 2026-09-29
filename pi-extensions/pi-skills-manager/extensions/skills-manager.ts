/**
 * kendex Pi Skills Manager.
 *
 * A polished /skill manager view for browsing, previewing, inserting, creating,
 * editing, renaming, deleting, and enabling/disabling Pi skills.
 */

import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { INSTALL_SYMBOL } from "./skills-manager/constants.js";
import { createSkillFromAnswers } from "./skills-manager/creation.js";
import { showSkillsManager } from "./skills-manager/dialog.js";
import { installSettingsCacheRefresh, recordProjectTrust } from "./skills-manager/package-config.js";
import { deleteSkill, loadSkillRegistry } from "./skills-manager/registry.js";
import { settingBoolean, updatePackageConfig } from "./skills-manager/settings.js";
import { patchInteractiveModeStartupSkillsBlock, setStartupHideEnabled } from "./skills-manager/startup.js";
import { setSkillEnabled } from "./skills-manager/toggle.js";
import type { SkillEntry } from "./skills-manager/types.js";

function errorMessage(error: unknown): string {
	const message = error instanceof Error ? error.message : String(error);
	return message.length > 180 ? `${message.slice(0, 179)}…` : message;
}

function insertNativeSkillCommand(ctx: ExtensionContext, skill: SkillEntry): void {
	ctx.ui.pasteToEditor(`/skill:${skill.name}\n`);
}

export default function skillsManager(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;

	patchInteractiveModeStartupSkillsBlock();
	setStartupHideEnabled(settingBoolean("enabled", true) && settingBoolean("hideStartupSkillsBlock", true));

	const enabledAtLoad = settingBoolean("enabled", true);

	if (!enabledAtLoad) {
		const enableRecovery = async (ctx: ExtensionCommandContext) => {
			updatePackageConfig(ctx.cwd, { enabled: true });
			ctx.ui.notify("Skills Manager enabled. Reloading...", "info");
			await ctx.reload();
		};
		pi.registerCommand("skill", {
			description: "Skills manager recovery command.",
			handler: async (args, ctx) => {
				if (args.trim().toLowerCase() !== "enable") {
					ctx.ui.notify("Skills Manager is disabled. Run /skill:enable, then /reload.", "warning");
					return;
				}
				await enableRecovery(ctx);
			},
		});
		pi.registerCommand("skill:enable", {
			description: "Re-enable the skills manager",
			handler: async (_args, ctx) => enableRecovery(ctx),
		});
		return;
	}

	// The inventory is loaded when /skill opens the manager and dropped when it
	// closes, so a session that never opens it, headless or not, holds none.
	function prepareSession(ctx: ExtensionContext): void {
		recordProjectTrust(ctx);
		setStartupHideEnabled(settingBoolean("enabled", true, ctx.cwd) && settingBoolean("hideStartupSkillsBlock", true, ctx.cwd));
	}

	pi.registerCommand("skill", {
		description: "Pi skills manager view. Native skills remain /skill:name.",
		handler: async (args, ctx) => {
			const rawArgs = args.trim();
			const trimmed = rawArgs.toLowerCase();
			if (trimmed === "enable") {
				updatePackageConfig(ctx.cwd, { enabled: true });
				ctx.ui.notify("Skills Manager already enabled.", "info");
				return;
			}
			if (trimmed === "disable") {
				updatePackageConfig(ctx.cwd, { enabled: false });
				ctx.ui.notify("Skills Manager disabled. Run /reload to unload commands/hooks.", "info");
				return;
			}
			if (rawArgs) {
				ctx.ui.notify("Use /skill:name for native skill invocation, or /skill with no arguments for the manager.", "warning");
				return;
			}
			if (!ctx.hasUI) {
				ctx.ui.notify("/skill manager requires interactive mode", "warning");
				return;
			}
			let registry;
			try {
				registry = await loadSkillRegistry(ctx.cwd);
			} catch (error) {
				ctx.ui.notify(`Failed to load skills list: ${errorMessage(error)}`, "error");
				return;
			}
			const selection = await showSkillsManager(ctx, registry, {
				onCreate: async (answers, signal) => await createSkillFromAnswers(ctx, answers, { thinkingLevel: pi.getThinkingLevel(), signal }),
				onDelete: async (skill) => await deleteSkill(ctx, skill),
				onToggle: async (skill, enabled) => await setSkillEnabled(ctx.cwd, skill, enabled),
				onRefresh: async () => await loadSkillRegistry(ctx.cwd),
			});
			if (selection) insertNativeSkillCommand(ctx, selection);
		},
	});

	installSettingsCacheRefresh(pi);
	pi.on("session_start", (_event, ctx) => { prepareSession(ctx); });
}
