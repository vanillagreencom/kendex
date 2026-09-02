import { readPackageConfig } from "./settings.js";

export type GlyphStyle = "unicode" | "ascii";
export type GlobalGlyphStyleOverride = "inherit" | GlyphStyle;

const LOCAL_CONFIG_ID = "@vanillagreen/pi-web-tools";
const GLOBAL_CONFIG_ID = "@vanillagreen/pi-tool-renderer";

function asGlyphStyle(value: unknown): GlyphStyle | undefined {
	return value === "unicode" || value === "ascii" ? value : undefined;
}

export function glyphStyle(cwd?: string): GlyphStyle {
	const globalOverride = readPackageConfig(GLOBAL_CONFIG_ID, cwd).globalGlyphStyleOverride;
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
