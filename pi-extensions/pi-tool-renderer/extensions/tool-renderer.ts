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
import { registerBash, registerEdit, registerRead, registerReadOnly, registerWrite } from "./tool-renderer/tools.js";

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
	const renderMutationTools = settingBoolean("renderMutationTools", false, cwd);
	const registerBatchTool = settingBoolean("registerBatchTool", true, cwd);
	// Pi refuses a whole extension when another one registered a tool of the same name at load, so the
	// replacements register at session_start and leave a name another extension owns to that extension.
	// A later session_start on this API finds this extension's own tools listed and registers none again.
	pi.on("session_start", () => {
		const taken = new Set(pi.getAllTools().filter((tool) => tool.sourceInfo.source !== "builtin").map((tool) => tool.name));
		const added: string[] = [];
		const register = (name: string, add: () => void) => {
			if (taken.has(name)) return;
			add();
			added.push(name);
		};
		register("read", () => registerRead(pi, agent, cwd));
		register("bash", () => registerBash(pi, agent, cwd));
		if (renderMutationTools) {
			register("edit", () => registerEdit(pi, agent, cwd));
			register("write", () => registerWrite(pi, agent, cwd));
		}
		for (const name of ["grep", "find", "ls"] as const) register(name, () => registerReadOnly(pi, agent, cwd, name));
		if (registerBatchTool) register("tool_batch", () => registerToolBatch(pi, cwd));
		// Pi activates every tool an extension registers at load; one registered later in place of a
		// built-in keeps the built-in's inactive state, which would drop grep, find and ls.
		if (added.length > 0) pi.setActiveTools([...new Set([...pi.getActiveTools(), ...added])]);
	});
}
