import { Theme, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { ansiGreen, stripAnsi } from "./ansi.js";
import { PENDING_QUEUE_THEME_PATCH_SYMBOL, STATUS_TEXT_ALIGNMENT_PATCH_SYMBOL } from "./constants.js";
import { settingBoolean } from "./settings.js";

interface PendingQueueThemePatch {
	originalFg: unknown;
	cwd?: string;
}

interface StatusTextAlignmentPatch {
	originalRender: (this: unknown, width: number) => string[];
}

function isStatusTextAlignmentPatch(value: unknown): value is StatusTextAlignmentPatch {
	return typeof value === "object" && value !== null && typeof (value as Partial<StatusTextAlignmentPatch>).originalRender === "function";
}

interface StatusTextClassification {
	text: string;
	status: boolean;
}

function isPendingQueuePreviewText(text: string): boolean {
	const plain = stripAnsi(text);
	return plain.startsWith("Steering: ") || plain.startsWith("Follow-up: ");
}

function isPendingQueueHintText(text: string): boolean {
	const plain = stripAnsi(text);
	return plain.startsWith("↳ ") && plain.includes("queued messages");
}

function pendingQueuePreviewLine(text: string): string {
	return ansiGreen(`┃ ${text}`);
}

function isQueuedMessageStatusText(text: string): boolean {
	const plain = stripAnsi(text);
	return /^Restored \d+ queued messages? to editor$/.test(plain) || plain === "No queued messages to restore";
}

/**
 * Pads Pi's dequeue status line ("Restored N queued messages to editor") flush
 * with the pending-queue preview. The patch wraps every pi-tui `Text`, so the
 * classification is cached per instance and recomputed only when its text
 * changes: an unchanged `Text`, which pi-tui answers from its own render
 * cache, pays one string comparison, not a scan of its whole text.
 */
export function installStatusTextAlignmentPatch(ctx: ExtensionContext): void {
	if (!ctx.hasUI) return;
	const proto = Text.prototype as unknown as Record<PropertyKey, any>;
	// Any marker already here keeps its wrapper, including pi-qol 2.2.0's `true`.
	if (proto[STATUS_TEXT_ALIGNMENT_PATCH_SYMBOL] !== undefined) return;
	const originalRender = proto.render;
	if (typeof originalRender !== "function") return;
	const classifications = new WeakMap<object, StatusTextClassification>();
	const isStatusText = (component: object, text: string): boolean => {
		const cached = classifications.get(component);
		if (cached && cached.text === text) return cached.status;
		const status = isQueuedMessageStatusText(text);
		classifications.set(component, { text, status });
		return status;
	};
	const patch: StatusTextAlignmentPatch = { originalRender };
	proto[STATUS_TEXT_ALIGNMENT_PATCH_SYMBOL] = patch;
	proto.render = function patchedQolStatusTextRender(this: any, width: number): string[] {
		const text = typeof this?.text === "string" ? this.text : "";
		if (!isStatusText(this, text)) return originalRender.call(this, width);
		const originalPaddingX = this.paddingX;
		try {
			this.paddingX = 0;
			this.invalidate?.();
			return originalRender.call(this, width);
		} finally {
			this.paddingX = originalPaddingX;
			this.invalidate?.();
		}
	};
}

/**
 * Removes the patch, but only one this module's install wrote. Any other
 * marker keeps its wrapper: pi-qol 2.2.0 marked the prototype with `true` and
 * kept no original render, and Pi's `/reload` carries that marker into this
 * module because pi-tui's prototype outlives the reload.
 */
export function restoreStatusTextAlignmentPatch(): void {
	const proto = Text.prototype as unknown as Record<PropertyKey, any>;
	const patch: unknown = proto[STATUS_TEXT_ALIGNMENT_PATCH_SYMBOL];
	if (!isStatusTextAlignmentPatch(patch)) return;
	proto.render = patch.originalRender;
	delete proto[STATUS_TEXT_ALIGNMENT_PATCH_SYMBOL];
}

export function installPendingQueueThemePatch(ctx: ExtensionContext): void {
	if (!ctx.hasUI) return;
	const proto = Theme.prototype as unknown as Record<PropertyKey, unknown>;
	const existing = proto[PENDING_QUEUE_THEME_PATCH_SYMBOL] as PendingQueueThemePatch | undefined;
	if (existing) {
		existing.cwd = ctx.cwd;
		return;
	}
	const originalFg = proto.fg;
	if (typeof originalFg !== "function") return;
	const patch: PendingQueueThemePatch = { originalFg, cwd: ctx.cwd };
	proto[PENDING_QUEUE_THEME_PATCH_SYMBOL] = patch;
	proto.fg = function patchedQolFg(this: Theme, token: string, text: string): string {
		if (token === "dim" && typeof text === "string" && settingBoolean("pendingQueue.asciiGreen", true, patch.cwd)) {
			if (isPendingQueuePreviewText(text)) return pendingQueuePreviewLine(text);
			if (isPendingQueueHintText(text)) return (patch.originalFg as (this: Theme, token: string, text: string) => string).call(this, token, `  ${text}`);
		}
		return (patch.originalFg as (this: Theme, token: string, text: string) => string).call(this, token, text);
	};
}

export function restorePendingQueueThemePatch(_ctx: ExtensionContext): void {
	const proto = Theme.prototype as unknown as Record<PropertyKey, unknown>;
	const patch = proto[PENDING_QUEUE_THEME_PATCH_SYMBOL] as PendingQueueThemePatch | undefined;
	if (!patch) return;
	proto.fg = patch.originalFg;
	delete proto[PENDING_QUEUE_THEME_PATCH_SYMBOL];
}
