import { readPackageConfig } from "./package-config.js";

export const CONFIG_ID = "@vanillagreen/pi-tool-renderer";

export type kendexConfig = Record<string, unknown>;

export function readkendexConfig(cwd?: string): kendexConfig {
	return readPackageConfig(CONFIG_ID, cwd) as kendexConfig;
}

export function settingNumber(key: string, fallback: number, cwd?: string): number {
	const value = readkendexConfig(cwd)[key];
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
	return Number.isFinite(parsed) ? parsed : fallback;
}

export function settingBoolean(key: string, fallback: boolean, cwd?: string): boolean {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "boolean" ? value : fallback;
}

export function settingString(key: string, fallback: string, cwd?: string): string {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "string" ? value : fallback;
}

export function settingEnum<T extends string>(key: string, allowed: readonly T[], fallback: T, cwd?: string): T {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "string" && (allowed as readonly string[]).includes(value) ? (value as T) : fallback;
}

export function rightMarginGuardEnabled(cwd?: string): boolean {
	return settingBoolean("rightMarginGuard", true, cwd);
}

export function stackToolCalls(cwd?: string): boolean {
	return settingBoolean("stackToolCalls", false, cwd);
}

export type StackChildDisplay = "rows" | "headline" | "anchor-list";

export function stackChildDisplay(cwd?: string): StackChildDisplay {
	const value = readkendexConfig(cwd).stackChildDisplay;
	if (value === "rows" || value === "headline" || value === "anchor-list") return value;
	return settingBoolean("hideStackChildRows", false, cwd) ? "headline" : "rows";
}

export function stackShell(cwd?: string): { renderShell?: "self" } {
	return stackToolCalls(cwd) ? { renderShell: "self" } : {};
}

export type ReadOutputMode = "hidden" | "summary" | "preview";
export type ReadImageMode = "off" | "always" | "on";
export type SearchOutputMode = "hidden" | "count" | "preview";
export type BashOutputMode = "hidden" | "summary" | "opencode" | "preview";
export type McpOutputMode = "hidden" | "summary" | "preview";

export function readOutputMode(cwd?: string): ReadOutputMode {
	return settingEnum("readOutputMode", ["hidden", "summary", "preview"] as const, "preview", cwd);
}

export function readImageMode(cwd?: string): ReadImageMode {
	const value = readkendexConfig(cwd).showReadImages;
	if (value === true || value === "on") return "on";
	if (value === "always") return "always";
	return "off";
}

export function searchOutputMode(cwd?: string): SearchOutputMode {
	return settingEnum("searchOutputMode", ["hidden", "count", "preview"] as const, "preview", cwd);
}

export function bashOutputMode(cwd?: string): BashOutputMode {
	return settingEnum("bashOutputMode", ["hidden", "summary", "opencode", "preview"] as const, "opencode", cwd);
}

export function bashLiveOutputDelayMs(cwd?: string): number {
	return Math.max(0, Math.floor(settingNumber("bashLiveOutputDelayMs", 1000, cwd)));
}

export function bashLiveTailLines(cwd?: string): number {
	return Math.max(1, Math.floor(settingNumber("bashLiveTailLines", 4, cwd)));
}

export function mcpOutputMode(cwd?: string): McpOutputMode {
	return settingEnum("mcpOutputMode", ["hidden", "summary", "preview"] as const, "preview", cwd);
}

export type TreeStyle = "unicode" | "ascii";

export function treeStyle(cwd?: string): TreeStyle {
	return settingEnum("treeStyle", ["unicode", "ascii"] as const, "unicode", cwd);
}

export function pendingStatusAnimation(cwd?: string): boolean {
	return settingBoolean("pendingStatusAnimation", false, cwd);
}

export function diffBackgroundEnabled(cwd?: string): boolean {
	return settingBoolean("diffBackgrounds", true, cwd);
}

export function bashDiffRenderingEnabled(cwd?: string): boolean {
	return settingBoolean("renderBashDiffs", false, cwd);
}

export type ToolChromeMode = "off" | "transparent" | "outlines";

export function toolChromeMode(cwd?: string): ToolChromeMode {
	return settingEnum("toolChrome", ["off", "transparent", "outlines"] as const, "outlines", cwd);
}
