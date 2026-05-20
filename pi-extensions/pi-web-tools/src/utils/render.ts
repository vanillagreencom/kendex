import { Text, truncateToWidth, type Component } from "@earendil-works/pi-tui";
import { glyphs, treeGlyph, truncateText } from "../glyphs.js";

export function emptyComponent(): Component {
	return { invalidate() {}, render: () => [] };
}

export function textComponent(text: string): Component {
	return new Text(text, 0, 0);
}

export function oneLine(value: unknown, max = 88): string {
	const text = String(value ?? "").replace(/\s+/g, " ").trim();
	return truncateText(text, max);
}

export function bullet(theme: any, tone: "accent" | "success" | "error" | "warning" = "accent"): string {
	return theme.fg(tone, glyphs().bullet);
}

export function toolLabel(theme: any, label: string): string {
	return theme.fg("text", theme.bold(label));
}

export function dim(theme: any, text: string): string {
	return theme.fg("dim", text);
}

export function muted(theme: any, text: string): string {
	return theme.fg("muted", text);
}

export function accent(theme: any, text: string): string {
	return theme.fg("accent", text);
}

export function tree(theme: any, branch: "├" | "└" | "│" = "└"): string {
	return theme.fg("muted", `  ${treeGlyph(branch)}`);
}

export function firstText(result: any): string {
	const part = result?.content?.find?.((candidate: any) => candidate?.type === "text" && typeof candidate.text === "string");
	return part?.text ?? "";
}

export function renderLines(lines: string[]): Component {
	return {
		invalidate() {},
		render(width: number): string[] {
			return lines.map((line) => truncateToWidth(line, Math.max(1, width), ""));
		},
	};
}

export function webCallText(theme: any, label: string, target: string, meta?: string): string {
	return `${bullet(theme)}${toolLabel(theme, `${label} `)}${accent(theme, oneLine(target, 92))}${meta ? dim(theme, ` · ${meta}`) : ""}`;
}

export function successSummary(theme: any, label: string, target: string, meta?: string): string {
	return `${bullet(theme, "success")}${toolLabel(theme, `${label} `)}${accent(theme, oneLine(target, 92))}${meta ? dim(theme, ` · ${meta}`) : ""}`;
}

export function providerDisplayName(provider: unknown): string {
	const value = String(provider ?? "").trim().toLowerCase();
	if (value.includes("/")) return value.split("/").map((part) => providerDisplayName(part)).join("/");
	if (value === "exa") return "Exa";
	if (value === "exa-mcp") return "Exa MCP";
	if (value === "duckduckgo") return "DuckDuckGo";
	if (value === "github") return "GitHub";
	if (value === "gemini") return "Gemini";
	if (value === "gemini-web") return "Gemini Web";
	if (value === "perplexity") return "Perplexity";
	if (value === "openai-native") return "OpenAI Native";
	if (value === "openai" || value === "openai-codex" || value === "codex") return "Codex";
	if (value === "http") return "HTTP";
	if (value === "jina") return "Jina";
	if (value === "http+jina") return "HTTP+Jina";
	if (value === "exa-code") return "Exa Code";
	if (value === "local") return "Local";
	if (value === "mixed") return "Mixed";
	if (value === "auto") return "Auto";
	if (value === "session" || value === "stored") return "Session";
	if (value === "resolving…" || value === "resolving...") return `Resolving${glyphs().ellipsis}`;
	return value ? value.replace(/(^|-)([a-z])/g, (_match, sep, char) => `${sep === "-" ? " " : ""}${char.toUpperCase()}`) : "Provider";
}

export function providerModeDisplayName(provider: unknown, mode?: unknown): string {
	const providerValue = String(provider ?? "").trim().toLowerCase();
	const modeValue = String(mode ?? "").trim().toLowerCase();
	if (providerValue === "exa" && modeValue) {
		if (modeValue === "lite" || modeValue === "deep-lite") return "Exa-Lite";
		if (modeValue === "standard" || modeValue === "full" || modeValue === "deep" || modeValue === "deep-reasoning") return "Exa-Deep";
	}
	return providerDisplayName(provider);
}

export function providerLabel(label: string, provider: unknown, mode?: unknown): string {
	return `${label} (${providerModeDisplayName(provider, mode)})`;
}

export function errorSummary(theme: any, label: string, message: string): string {
	return `${bullet(theme, "error")}${toolLabel(theme, `${label} `)}${theme.fg("error", oneLine(message, 120))}`;
}
