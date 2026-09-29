import { existsSync, readFileSync } from "node:fs";
import { basename, resolve } from "node:path";
import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { applyVisibleReplacements, buildVisibleMap, type VisibleReplacement } from "./ansi.js";
import { IMAGE_EXTENSIONS, IMAGE_PATH_PATTERN } from "./constants.js";
import { expandHome } from "./package-config.js";
import { settingBoolean } from "./settings.js";

function stripAtPrefix(path: string): string {
	return path.startsWith("@") ? path.slice(1) : path;
}

export function resolveMaybeImagePath(path: string, cwd: string): string | undefined {
	const clean = stripAtPrefix(path);
	const expanded = expandHome(clean);
	const resolved = expanded.startsWith("/") ? expanded : resolve(cwd, expanded);
	const lower = resolved.toLowerCase();
	const dot = lower.lastIndexOf(".");
	if (dot < 0 || !IMAGE_EXTENSIONS.has(lower.slice(dot))) return undefined;
	if (!existsSync(resolved)) return undefined;
	return resolved;
}

function imagePathLabels(text: string, cwd: string): string[] {
	const seen = new Set<string>();
	for (const match of text.matchAll(IMAGE_PATH_PATTERN)) {
		const resolved = resolveMaybeImagePath(match[2] ?? "", cwd);
		if (resolved) seen.add(`Image ${basename(resolved)}`);
	}
	return [...seen].sort();
}

function mimeTypeForPath(path: string): string {
	const lower = path.toLowerCase();
	if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) return "image/jpeg";
	if (lower.endsWith(".gif")) return "image/gif";
	if (lower.endsWith(".webp")) return "image/webp";
	if (lower.endsWith(".bmp")) return "image/bmp";
	if (lower.endsWith(".tif") || lower.endsWith(".tiff")) return "image/tiff";
	if (lower.endsWith(".heic")) return "image/heic";
	if (lower.endsWith(".heif")) return "image/heif";
	return "image/png";
}

export function imageContentForPath(path: string): { type: "image"; data: string; mimeType: string } | undefined {
	try {
		return { data: readFileSync(path).toString("base64"), mimeType: mimeTypeForPath(path), type: "image" };
	} catch {
		return undefined;
	}
}

export function attachmentLabels(text: string, cwd = process.cwd()): string[] {
	const seen = new Set<string>();
	for (const match of text.matchAll(/\[Image\s+#(\d+)\]/gi)) {
		seen.add(`Image #${match[1]}`);
	}
	for (const label of imagePathLabels(text, cwd)) seen.add(label);
	return [...seen].sort((a, b) => Number(a.replace(/\D/g, "")) - Number(b.replace(/\D/g, "")) || a.localeCompare(b));
}

function chip(label: string, theme?: Theme): string {
	const text = ` ${label} `;
	if (theme) return theme.fg("accent", theme.inverse(text));
	return `[${label}]`;
}

function imageChipReplacements(visibleText: string, cwd: string, theme?: Theme): VisibleReplacement[] {
	const replacements: VisibleReplacement[] = [];

	for (const match of visibleText.matchAll(/\[Image\s+#(\d+)\]/gi)) {
		const start = match.index ?? 0;
		replacements.push({
			start,
			end: start + match[0].length,
			text: chip(`Image #${match[1]}`, theme),
		});
	}

	let imageIndex = 0;
	for (const match of visibleText.matchAll(IMAGE_PATH_PATTERN)) {
		const prefix = match[1] ?? "";
		const rawPath = match[2] ?? "";
		const resolved = resolveMaybeImagePath(rawPath, cwd);
		if (!resolved) continue;

		imageIndex += 1;
		const start = (match.index ?? 0) + prefix.length;
		replacements.push({
			start,
			end: start + rawPath.length,
			text: chip(`Image ${imageIndex}`, theme),
		});
	}

	return replacements;
}

export function styleImageChips(line: string, cwd: string, theme?: Theme): string {
	if (!settingBoolean("showImageChips", true, cwd)) return line;
	const map = buildVisibleMap(line);
	const replacements = imageChipReplacements(map.text, cwd, theme);
	return replacements.length === 0 ? line : applyVisibleReplacements(line, map, replacements);
}

export function statusText(ctx: ExtensionContext, text: string): string | undefined {
	if (!settingBoolean("showAttachmentCountInStatus", true, ctx.cwd)) return undefined;
	const count = attachmentLabels(text, ctx.cwd).length;
	return count > 0 ? `images:${count}` : undefined;
}

/// Resolve every image-path-shaped substring in submitted text to an
/// absolute file path. Used by the `input` event to replace the previous
/// approach of mutating the editor buffer to `[Image #N]` aliases via a
/// 250ms polling timer (which raced with resize/input handling).
export function resolveSubmittedImagePaths(text: string, cwd: string): string[] {
	const paths = new Set<string>();
	for (const match of text.matchAll(IMAGE_PATH_PATTERN)) {
		const resolved = resolveMaybeImagePath(match[2] ?? "", cwd);
		if (resolved) paths.add(resolved);
	}
	return [...paths];
}

