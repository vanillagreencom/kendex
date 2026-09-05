import { host } from "./host.js";

export type GlyphStyle = "unicode" | "ascii";
export type GlobalGlyphStyleOverride = "inherit" | GlyphStyle;

const LOCAL_CONFIG_ID = "@vanillagreen/pi-extension-manager";
const GLOBAL_CONFIG_ID = "@vanillagreen/pi-tool-renderer";

function projectSettingsPath(cwd: string): string {
	return host.settingsPath("project", cwd);
}

const PROJECT_TRUST_SYMBOL = Symbol.for("kendex.pi.project-trust");

interface ProjectTrustRegistry {
	projectSettings?: Map<string, boolean>;
}

function projectTrustRegistry(): ProjectTrustRegistry {
	const host = globalThis as unknown as Record<PropertyKey, ProjectTrustRegistry | undefined>;
	const existing = host[PROJECT_TRUST_SYMBOL];
	if (existing) return existing;
	const created: ProjectTrustRegistry = {};
	host[PROJECT_TRUST_SYMBOL] = created;
	return created;
}

export function recordProjectTrust(ctx: { cwd?: string; isProjectTrusted?: () => boolean }): void {
	if (!ctx.cwd) return;
	let trusted = true;
	try {
		trusted = ctx.isProjectTrusted?.() === true;
	} catch {
		trusted = false;
	}
	const registry = projectTrustRegistry();
	if (!registry.projectSettings) registry.projectSettings = new Map();
	registry.projectSettings.set(projectSettingsPath(ctx.cwd), trusted);
}

function projectSettingsTrusted(settingsPath: string): boolean {
	return projectTrustRegistry().projectSettings?.get(settingsPath) === true;
}

function readPackageConfig(packageId: string, cwd = process.cwd()): Record<string, unknown> {
	const merged: Record<string, unknown> = {};
	try {
		const files = host.settings({ cwd, isProjectTrusted: () => projectSettingsTrusted(projectSettingsPath(cwd)) });
		for (const file of files) {
			const parsed = file.json as { kendex?: { extensionManager?: { config?: Record<string, unknown> } } };
			const config = parsed.kendex?.extensionManager?.config?.[packageId];
			if (config && typeof config === "object" && !Array.isArray(config)) Object.assign(merged, config);
		}
	} catch {
		// Optional glyph settings cannot prevent a diagnostic from rendering.
	}
	return merged;
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
