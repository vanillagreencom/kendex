import { CompactionSummaryMessageComponent, type ExtensionAPI } from "@earendil-works/pi-coding-agent";

import { registerToolBatch } from "./tool-renderer/batch.js";
import {
	installToolChromePatch,
	installToolExecutionRendererPatch,
	installWorkingIndicator,
	installWorkingLoaderAlignmentPatch,
	registerToolChromeEvents,
} from "./tool-renderer/chrome.js";
import {
	installAssistantMessageRenderer,
	installCompactionSummaryRenderer,
	installCustomMessageSpacingPatch,
	installMarkdownCodeBlockRenderer,
	installSkillInvocationRenderer,
	installUserMessageRenderer,
} from "./tool-renderer/messages.js";
import { installLiveSettingsRefresh } from "./tool-renderer/live-settings.js";
import { installSettingsCacheRefresh, recordProjectTrust } from "./tool-renderer/package-config.js";
import { settingBoolean } from "./tool-renderer/settings.js";
import { registerStackEvents } from "./tool-renderer/stack.js";
import { registerBlinkEvents } from "./tool-renderer/text.js";
import { createBashRenderers, createEditRenderers, createReadRenderers, createReadOnlyRenderers, createWriteRenderers, registerWriteDiffEvents } from "./tool-renderer/tools.js";

const INSTALL_SYMBOL = Symbol.for("kendex.pi-tool-renderer.installed");

export default async function toolRenderer(pi: ExtensionAPI): Promise<void> {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;
	if (!settingBoolean("enabled", true)) return;
	installSettingsCacheRefresh(pi);
	pi.on("session_start", (_event, ctx) => recordProjectTrust(ctx));

	registerStackEvents(pi);
	registerBlinkEvents(pi);
	installToolExecutionRendererPatch(pi);
	installLiveSettingsRefresh(pi);
	installToolChromePatch();
	registerToolChromeEvents(pi);
	installWorkingLoaderAlignmentPatch();
	installWorkingIndicator(pi);
	installMarkdownCodeBlockRenderer(pi);
	installCompactionSummaryRenderer(pi, CompactionSummaryMessageComponent);

	const agent = await import("@earendil-works/pi-coding-agent");
	installUserMessageRenderer(pi, agent.UserMessageComponent);
	installAssistantMessageRenderer(pi, agent.AssistantMessageComponent);
	installCustomMessageSpacingPatch(pi, (agent as any).CustomMessageComponent);
	installSkillInvocationRenderer(pi, (agent as any).SkillInvocationMessageComponent);
	const cwd = process.cwd();
	const read = createReadRenderers(cwd);
	const bash = createBashRenderers(cwd);
	const grep = createReadOnlyRenderers(cwd, "grep");
	const find = createReadOnlyRenderers(cwd, "find");
	const ls = createReadOnlyRenderers(cwd, "ls");
	const renderMutationTools = settingBoolean("renderMutationTools", false, cwd);
	const edit = renderMutationTools ? createEditRenderers(cwd) : undefined;
	const write = renderMutationTools ? createWriteRenderers(cwd) : undefined;
	if (renderMutationTools) registerWriteDiffEvents(pi);
	pi.registerToolRenderer((toolName, next) => {
		switch (toolName) {
			case "read": return read;
			case "bash": return bash;
			case "grep": return grep;
			case "find": return find;
			case "ls": return ls;
			case "edit": return edit ?? next();
			case "write": return write ?? next();
			default: return next();
		}
	});
	if (settingBoolean("registerBatchTool", true, cwd)) registerToolBatch(pi, cwd);
}
