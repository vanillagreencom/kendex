import { host } from "./host.js";
import { recordSettingsTrust, settingsFileTrusted, settingsMemo } from "./package-config.js";

export type GlyphStyle = "unicode" | "ascii";
export type GlobalGlyphStyleOverride = "inherit" | GlyphStyle;

const LOCAL_CONFIG_ID = "@vanillagreen/pi-extension-manager";
const GLOBAL_CONFIG_ID = "@vanillagreen/pi-tool-renderer";

function projectSettingsPath(cwd: string): string {
	return host.settingsPath("project", cwd);
}

export function recordProjectTrust(ctx: { cwd?: string; isProjectTrusted?: () => boolean }): void {
	if (!ctx.cwd) return;
	recordSettingsTrust(projectSettingsPath(ctx.cwd), ctx);
}

/** Read through the host, which knows OMP's YAML documents, and memoized for
 * the settings window: the manager list renders glyphs per row per frame. */
function readPackageConfig(packageId: string, cwd = process.cwd()): Record<string, unknown> {
	return settingsMemo(`manager-glyph-config\0${packageId}\0${cwd}`, () => {
		const merged: Record<string, unknown> = {};
		try {
			const files = host.settings({ cwd, isProjectTrusted: () => settingsFileTrusted(projectSettingsPath(cwd)) });
			for (const file of files) {
				const parsed = file.json as { kendex?: { extensionManager?: { config?: Record<string, unknown> } } };
				const config = parsed.kendex?.extensionManager?.config?.[packageId];
				if (config && typeof config === "object" && !Array.isArray(config)) Object.assign(merged, config);
			}
		} catch {
			// Optional glyph settings cannot prevent a diagnostic from rendering.
		}
		return merged;
	});
}

function asGlyphStyle(value: unknown): GlyphStyle | undefined {
	return value === "unicode" || value === "ascii" ? value : undefined;
}

export function glyphStyle(cwd?: string): GlyphStyle {
	const globalOverride = host.settingsSupported(GLOBAL_CONFIG_ID) ? readPackageConfig(GLOBAL_CONFIG_ID, cwd).globalGlyphStyleOverride : undefined;
	const forced = asGlyphStyle(globalOverride);
	if (forced) return forced;
	const local = readPackageConfig(LOCAL_CONFIG_ID, cwd);
	return asGlyphStyle(local.glyphStyle) ?? asGlyphStyle(local.treeStyle) ?? "unicode";
}

export const GLYPHS = {
	unicode: {
		frame: { tl: "┏", tr: "┓", bl: "┗", br: "┛", h: "━", v: "┃" },
		line: "─",
		tree: { mid: "├─ ", last: "└─ ", stem: "│  ", blank: "   " },
		bullet: "● ",
		emptyBullet: "○ ",
		dot: " · ",
		ok: "✓",
		fail: "✗",
		warn: "▲",
		diamond: "◆",
		prompt: "π",
		ellipsis: "…",
		arrow: "→",
		codeBar: "▌",
	},
	ascii: {
		frame: { tl: "+", tr: "+", bl: "+", br: "+", h: "-", v: "|" },
		line: "-",
		tree: { mid: "|-- ", last: "`-- ", stem: "|  ", blank: "   " },
		bullet: "* ",
		emptyBullet: "o ",
		dot: " - ",
		ok: "+",
		fail: "x",
		warn: "!",
		diamond: "*",
		prompt: "pi",
		ellipsis: "...",
		arrow: "->",
		codeBar: "|",
	},
} as const;

export function glyphs(cwd?: string): (typeof GLYPHS)[GlyphStyle] {
	return GLYPHS[glyphStyle(cwd)];
}

export function truncateIndicator(cwd?: string): string {
	return glyphs(cwd).ellipsis;
}

export function truncateText(text: string, maxChars: number, cwd?: string): string {
	if (text.length <= maxChars) return text;
	const indicator = truncateIndicator(cwd);
	return `${text.slice(0, Math.max(0, maxChars - indicator.length))}${indicator}`;
}

export function dot(cwd?: string): string {
	return glyphs(cwd).dot;
}

export function treeGlyph(branch: "├" | "└" | "│", cwd?: string): string {
	const tree = glyphs(cwd).tree;
	if (branch === "│") return tree.stem;
	return branch === "└" ? tree.last : tree.mid;
}

export function frameGlyphs(cwd?: string): (typeof GLYPHS)[GlyphStyle]["frame"] {
	return glyphs(cwd).frame;
}
