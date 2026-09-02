import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import type { InventoryItem } from "./types.js";
import { piGlobalRoot } from "./pi-root.js";

function piUserDir(): string {
	return piGlobalRoot();
}

export function findAppendSystemScopeRoot(packageDir: string): string | undefined {
	let dir = resolve(packageDir);
	while (true) {
		const parent = dirname(dir);
		if (parent === dir) return undefined;
		if (parent.endsWith("/packages") || parent.endsWith("\\packages")) return dirname(parent);
		const grandparent = dirname(parent);
		const isNodeModules = parent.endsWith("/node_modules") || parent.endsWith("\\node_modules");
		const isPiNpmRoot = grandparent.endsWith("/npm") || grandparent.endsWith("\\npm");
		if (isNodeModules && isPiNpmRoot) {
			const scopeRoot = dirname(grandparent);
			if (isPiScopeRoot(scopeRoot)) return scopeRoot;
		}
		dir = parent;
	}
}

function isPiScopeRoot(scopeRoot: string): boolean {
	if (existsSync(join(scopeRoot, "settings.json"))) return true;
	if (basename(scopeRoot) === ".pi") return true;
	return resolve(scopeRoot) === piUserDir();
}

function appendSystemMarkers(name: string): { begin: string; end: string } {
	return {
		begin: `<!-- kendex:append-system ${name} begin -->`,
		end: `<!-- kendex:append-system ${name} end -->`,
	};
}

function appendSystemStripBlock(existing: string, begin: string, end: string): string {
	// Splice the begin..end span out without touching surrounding newlines,
	// then collapse 3+ consecutive newlines so a removed sandwiched block
	// doesn't leave a gap. trim leading/trailing newlines last.
	let out = "";
	let rest = existing;
	while (true) {
		const start = rest.indexOf(begin);
		if (start < 0) break;
		out += rest.slice(0, start);
		const after = rest.slice(start + begin.length);
		const endIdx = after.indexOf(end);
		if (endIdx < 0) {
			out += begin;
			rest = after;
			break;
		}
		rest = after.slice(endIdx + end.length);
	}
	out += rest;
	return out.replace(/\n{3,}/g, "\n\n").replace(/^\n+/, "").replace(/\n+$/, "");
}

function appendSystemUpsert(target: string, name: string, content: string): void {
	const trimmed = content.trim();
	if (!trimmed) return appendSystemRemove(target, name);
	const { begin, end } = appendSystemMarkers(name);
	const block = `${begin}\n${trimmed}\n${end}`;
	const existing = existsSync(target) ? readFileSync(target, "utf8") : "";
	const stripped = appendSystemStripBlock(existing, begin, end);
	const next = stripped ? `${stripped}\n\n${block}\n` : `${block}\n`;
	if (next === existing) return;
	mkdirSync(dirname(target), { recursive: true });
	writeFileSync(target, next);
}

export function appendSystemRemove(target: string, name: string): void {
	if (!existsSync(target)) return;
	const { begin, end } = appendSystemMarkers(name);
	const existing = readFileSync(target, "utf8");
	if (!existing.includes(begin)) return;
	const stripped = appendSystemStripBlock(existing, begin, end);
	if (stripped) {
		const next = `${stripped}\n`;
		if (next === existing) return;
		writeFileSync(target, next);
	} else {
		try {
			unlinkSync(target);
		} catch (err) {
			if ((err as NodeJS.ErrnoException)?.code !== "ENOENT") throw err;
		}
	}
}

/**
 * Pi extension packages can declare `pi.appendSystem` in their package.json,
 * pointing at a markdown file whose contents are mirrored into the scope's
 * `APPEND_SYSTEM.md` so models receive extension-specific tool-usage rules.
 *
 * On enable/install: upsert a delimited block keyed by package name.
 * On disable/uninstall: remove that block.
 *
 * Marker format matches the vendored `scripts/append-system.mjs` shipped
 * with each extension and the Rust helpers in kendex's CLI.
 */
export function syncAppendSystemForPackage(item: InventoryItem, willDisable: boolean): void {
	if (item.kind !== "package" || !item.packageName || !item.packageDir) return;
	const pkgJsonPath = join(item.packageDir, "package.json");
	let manifest: { pi?: { appendSystem?: unknown } } | undefined;
	try {
		manifest = JSON.parse(readFileSync(pkgJsonPath, "utf8"));
	} catch (error) {
		console.warn(`pi-extension-manager: unable to read appendSystem manifest for ${item.packageName}: ${String(error)}`);
		return;
	}
	const rel = manifest?.pi?.appendSystem;
	if (typeof rel !== "string") return;

	const scopeRoot = findAppendSystemScopeRoot(item.packageDir);
	if (!scopeRoot) {
		console.warn(`pi-extension-manager: unable to resolve APPEND_SYSTEM.md scope for ${item.packageName}`);
		return;
	}
	const target = join(scopeRoot, "APPEND_SYSTEM.md");

	try {
		if (willDisable) {
			appendSystemRemove(target, item.packageName);
		} else {
			const sourcePath = resolve(item.packageDir, rel);
			if (!existsSync(sourcePath)) {
				console.warn(`pi-extension-manager: appendSystem source missing for ${item.packageName}: ${sourcePath}`);
				return;
			}
			const content = readFileSync(sourcePath, "utf8").trim();
			if (!content) {
				console.warn(`pi-extension-manager: appendSystem source is empty for ${item.packageName}: ${sourcePath}`);
				return;
			}
			appendSystemUpsert(target, item.packageName, content);
		}
	} catch (error) {
		// Best-effort: never block toggle on APPEND_SYSTEM.md write errors.
		console.warn(`pi-extension-manager: failed to update APPEND_SYSTEM.md for ${item.packageName}: ${String(error)}`);
	}
}

/**
 * Best-effort APPEND_SYSTEM.md cleanup for an uninstall path that did not
 * already handle it. Removes by package name only — we do not need the
 * package's `pi.appendSystem` declaration here, since the marker block is
 * keyed by name and remove-by-name is idempotent. Tries the scope's Pi dir
 * (which is where settings.json lives), and additionally the conventional
 * global Pi dir as a backstop for legacy global-prefix npm packages whose
 * package dir lives outside any managed `<scope>/packages/` or
 * `<scope>/npm/node_modules/` tree.
 */
export function removeAppendSystemBlockForUninstall(item: InventoryItem): void {
	if (!item.packageName) return;
	const targets = new Set<string>();
	if (item.packageDir) {
		const scopeRoot = findAppendSystemScopeRoot(item.packageDir);
		if (scopeRoot) targets.add(join(scopeRoot, "APPEND_SYSTEM.md"));
	}
	const piDir = piUserDir();
	if (existsSync(piDir)) targets.add(join(piDir, "APPEND_SYSTEM.md"));
	for (const target of targets) {
		try {
			appendSystemRemove(target, item.packageName);
		} catch {
			// Best-effort: never block uninstall on APPEND_SYSTEM.md write errors.
		}
	}
}
