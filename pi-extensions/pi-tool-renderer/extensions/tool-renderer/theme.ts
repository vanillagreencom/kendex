import { glyphs, glyphStyle, treeGlyph as configuredTreeGlyph } from "./glyphs.js";

export const FALLBACK_THEME = {
	bg(_token: string, text: string) {
		return text;
	},
	bold(text: string) {
		return `\x1b[1m${text}\x1b[22m`;
	},
	fg(_token: string, text: string) {
		return text;
	},
};

export function fgToken(theme: any, token: string, text: string, rejectTextFallback = false): string | undefined {
	try {
		const styled = theme?.fg?.(token, text);
		if (typeof styled !== "string" || styled === text) return undefined;
		if (rejectTextFallback && token !== "text") {
			try {
				const textStyled = theme?.fg?.("text", text);
				if (typeof textStyled === "string" && textStyled !== text && styled === textStyled) return undefined;
			} catch {
				// Ignore and accept the token styling.
			}
		}
		return styled;
	} catch {
		return undefined;
	}
}

export function subtleRule(theme: any, text: string): string {
	return fgToken(theme, "borderMuted", text, true)
		?? fgToken(theme, "muted", text, true)
		?? fgToken(theme, "dim", text, true)
		?? `\x1b[90m${text}\x1b[39m`;
}

export function toolRule(theme: any, text: string): string {
	return fgToken(theme, "muted", text, true) ?? fgToken(theme, "dim", text, true) ?? text;
}

export function borderMuted(theme: any, text: string): string {
	return subtleRule(theme, text);
}

export type TreeBranch = "├" | "└" | "│";

export function treeGlyph(branch: TreeBranch, cwd?: string): string {
	const glyph = configuredTreeGlyph(branch, cwd);
	return glyphStyle(cwd) === "ascii" ? glyph : `  ${glyph}`;
}

export function treeConnector(theme: any, branch: TreeBranch = "├", cwd?: string): string {
	return toolRule(theme, treeGlyph(branch, cwd));
}

export function treeStem(theme: any, branch: TreeBranch, cwd?: string): string {
	if (branch === "└") return theme.fg("muted", glyphStyle(cwd) === "ascii" ? "    " : "     ");
	return treeConnector(theme, "│", cwd);
}

export function toolLabel(theme: any, label: string): string {
	return theme.fg("text", theme.bold(label));
}

export function stackPrefix(theme: any, cwd?: string): string {
	return theme.fg("accent", glyphs(cwd).bullet);
}
