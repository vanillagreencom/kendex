import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { compactionProfile } from "./compaction.js";
import {
	DEFAULT_AUTO_RENAME_MODEL,
	DEFAULT_COMPACTION_MODEL,
	DEFAULT_IDLE_COMPACTION_SECONDS,
	DEFAULT_PERMISSION_GATE_PREVIEW_CHARS,
	DEFAULT_PERMISSION_GATE_PREVIEW_LINES,
} from "./constants.js";
import { currentEditorText } from "./editor.js";
import { glyphs } from "./glyphs.js";
import { attachmentLabels } from "./images.js";
import { permissionGateCommands } from "./permission-gate.js";
import { autoRenameEnabled } from "./session-rename.js";
import { sessionSearchShortcut } from "./session-search/index.js";
import { boundedSettingNumber, newlineFallbackKey, settingBoolean, settingNumber, settingString } from "./settings.js";

export function statusMessage(ctx: ExtensionContext): string {
	const labels = attachmentLabels(currentEditorText(ctx), ctx.cwd);
	const searchShortcut = sessionSearchShortcut(ctx.cwd);
	const statuslineEnabled = settingBoolean("statusline.enabled", true, ctx.cwd);
	const statuslineMode = statuslineEnabled
		? (settingBoolean("replaceFooter", true, ctx.cwd) ? "enabled, replaces footer" : "enabled, footer preserved")
		: "disabled";
	return [
		"Pi QOL status",
		`Statusline: ${statuslineMode}; prompt=${settingBoolean("compactPrompt", true, ctx.cwd) ? `${glyphs(ctx.cwd).prompt} compact` : "default chrome"}`,
		`shift+enter newline: ${settingBoolean("newlineOnShiftEnter", true, ctx.cwd) ? "enabled" : "disabled"}`,
		`Fallback newline key: ${newlineFallbackKey(ctx.cwd)}`,
		`Pending queue preview: ${settingBoolean("pendingQueue.asciiGreen", true, ctx.cwd) ? "ANSI green" : "Pi default"}`,
		`Image chips: ${settingBoolean("showImageChips", true, ctx.cwd) ? "filled (placeholders and existing image paths)" : "off"}`,
		`Image placeholders/paths in draft: ${labels.length ? labels.join(", ") : "none"}`,
		`Rename command: ${settingBoolean("enableSessionNameCommand", true, ctx.cwd) ? "enabled (/rename)" : "disabled"}`,
		`Auto session rename: ${autoRenameEnabled(ctx.cwd) ? `enabled (${settingString("sessionAutoRename.model", DEFAULT_AUTO_RENAME_MODEL, ctx.cwd)})` : "disabled"}`,
		`Handoff command: ${settingBoolean("enableHandoffCommand", true, ctx.cwd) ? "enabled" : "disabled"}`,
		`Schedule command: ${settingBoolean("enableScheduleCommand", true, ctx.cwd) ? "enabled (/schedule)" : "disabled"}`,
		`Handoff prompt review: ${settingBoolean("handoffReviewPrompt", true, ctx.cwd) ? "enabled" : "disabled"}`,
		`Session search: ${settingBoolean("sessionSearch.enabled", true, ctx.cwd) ? `enabled (/search${searchShortcut ? `, ${searchShortcut}` : ""})` : "disabled"}`,
		`Custom compaction: ${settingBoolean("compaction.customEnabled", false, ctx.cwd) ? `enabled (${settingString("compaction.model", DEFAULT_COMPACTION_MODEL, ctx.cwd)}, ${compactionProfile(ctx.cwd)})` : "disabled (Pi default)"}`,
		`Idle compaction: ${settingBoolean("compaction.idleEnabled", false, ctx.cwd) ? `enabled after ${Math.max(1, Math.floor(settingNumber("compaction.idleTimeoutSeconds", DEFAULT_IDLE_COMPACTION_SECONDS, ctx.cwd)))}s idle` : "disabled"}`,
		`Branch summary override: ${settingBoolean("compaction.branchSummaryEnabled", false, ctx.cwd) ? "enabled" : "disabled"}`,
		`Notifications: ${settingBoolean("notification.enabled", true, ctx.cwd) ? `enabled (bell=${settingBoolean("notification.bell", true, ctx.cwd)}, muteBell=${settingBoolean("notification.muteBellSound", false, ctx.cwd)}, native=${settingBoolean("notification.native", true, ctx.cwd)}, tmuxClientTty=${settingBoolean("notification.tmuxNativeClientTty", true, ctx.cwd)}, tmuxMessage=${settingBoolean("notification.tmux", false, ctx.cwd)})` : "disabled"}`,
		`Permission gate: ${settingBoolean("permissionGate.enabled", false, ctx.cwd) ? `enabled (${permissionGateCommands(ctx.cwd).join(", ") || "none configured"}; preview ${boundedSettingNumber("permissionGate.previewLines", DEFAULT_PERMISSION_GATE_PREVIEW_LINES, 4, 40, ctx.cwd)} lines/${boundedSettingNumber("permissionGate.previewChars", DEFAULT_PERMISSION_GATE_PREVIEW_CHARS, 200, 5000, ctx.cwd)} chars)` : "disabled"}`,
		`Thinking timer: ${settingBoolean("thinkingTimer.enabled", true, ctx.cwd) ? "enabled" : "disabled"}`,
		"If shift+enter still submits, configure your terminal/tmux to send a distinct shift+enter sequence or use the fallback key.",
	].join("\n");
}
