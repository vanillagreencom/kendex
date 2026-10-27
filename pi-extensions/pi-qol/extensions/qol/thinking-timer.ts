import { AssistantMessageComponent, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { THINKING_LABEL_DEFAULT, THINKING_TIMER_PATCH_SYMBOL, THINKING_TIMER_STORE_SYMBOL } from "./constants.js";
import { settingString } from "./settings.js";

export interface ThinkingTimerStore {
	cwd?: string;
	enabled: boolean;
	starts: Map<string, number>;
	durations: Map<string, number>;
	labels: Map<string, Text>;
	theme?: ExtensionContext["ui"]["theme"];
}

export function getThinkingTimerStore(): ThinkingTimerStore | undefined {
	return (globalThis as unknown as Record<PropertyKey, unknown>)[THINKING_TIMER_STORE_SYMBOL] as ThinkingTimerStore | undefined;
}

export function formatThinkingElapsed(ms: number): string {
	const totalSeconds = ms / 1000;
	if (totalSeconds < 60) return `${totalSeconds.toFixed(1)}s`;
	const minutes = Math.floor(totalSeconds / 60);
	const seconds = totalSeconds - minutes * 60;
	return `${minutes}:${seconds.toFixed(1).padStart(4, "0")}`;
}

export function thinkingLabel(cwd?: string): string {
	const configured = settingString("thinkingLabel.text", THINKING_LABEL_DEFAULT, cwd);
	return configured.trim() ? configured : THINKING_LABEL_DEFAULT;
}

export function thinkingTimerLabel(theme: ThinkingTimerStore["theme"], ms: number, cwd?: string): string {
	const base = thinkingLabel(cwd);
	const separator = /\s$/.test(base) ? "" : " ";
	const elapsed = `${separator}${formatThinkingElapsed(ms)}`;
	if (!theme) return `${base}${elapsed}`;
	return theme.italic(theme.fg("muted", base) + theme.fg("dim", elapsed));
}

export function hiddenThinkingLabel(theme: ThinkingTimerStore["theme"], cwd?: string): string {
	const base = thinkingLabel(cwd);
	return theme ? theme.fg("muted", base) : base;
}

export function thinkingTimerKey(timestamp: number, contentIndex: number): string {
	return `${timestamp}:${contentIndex}`;
}

export function installThinkingTimerPatch(): void {
	const proto = AssistantMessageComponent.prototype as unknown as Record<PropertyKey, any>;
	if (proto[THINKING_TIMER_PATCH_SYMBOL]) return;
	const originalUpdateContent = proto.updateContent;
	if (typeof originalUpdateContent !== "function") return;
	proto[THINKING_TIMER_PATCH_SYMBOL] = true;
	proto.updateContent = function patchedUpdateContent(this: any, message: any): void {
		originalUpdateContent.call(this, message);
		try {
			const store = getThinkingTimerStore();
			if (!store?.enabled) return;
			if (!message || !Array.isArray(message.content) || typeof message.timestamp !== "number") return;
			if (!this.hideThinkingBlock) return;
			if (!this.contentContainer || !Array.isArray(this.contentContainer.children)) return;

			const thinkingIndices: number[] = [];
			for (let i = 0; i < message.content.length; i++) {
				const content = message.content[i];
				if (content?.type === "thinking" && typeof content.thinking === "string" && content.thinking.trim()) thinkingIndices.push(i);
			}
			if (thinkingIndices.length === 0) return;

			const labelComponents: Text[] = [];
			for (const child of this.contentContainer.children as any[]) {
				if (!child || typeof child !== "object") continue;
				// Pi's SDK setHiddenThinkingLabel applies one label globally, not per block.
				// Until it supports per-block labels, depend on the private contentContainer
				// and MouseRegion.child (verified at Pi 0.86.0 and 1.0.1).
				const label = child.child ?? child;
				if (typeof label.setText !== "function") continue;
				if (typeof label.text !== "string") continue;
				const expectedLabel = thinkingLabel(store.cwd);
				if (!label.text.includes(expectedLabel) && !label.text.includes("Thinking...")) continue;
				labelComponents.push(label as Text);
			}
			if (labelComponents.length === 0) return;

			const count = Math.min(thinkingIndices.length, labelComponents.length);
			for (let i = 0; i < count; i++) {
				const contentIndex = thinkingIndices[i]!;
				const label = labelComponents[i]!;
				const key = thinkingTimerKey(message.timestamp, contentIndex);
				store.labels.set(key, label);
				const duration = store.durations.get(key);
				const start = store.starts.get(key);
				const ms = duration ?? (start === undefined ? undefined : Date.now() - start);
				if (ms !== undefined) label.setText(thinkingTimerLabel(store.theme, ms, store.cwd));
			}
		} catch {
			// Rendering must never break because of this optional monkey-patch.
		}
	};
}
