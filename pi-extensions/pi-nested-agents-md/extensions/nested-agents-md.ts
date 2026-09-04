import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";

import { getBool, projectRoot, readConfig, recordProjectTrust } from "./config.js";

const INSTALL_SYMBOL = Symbol.for("kendex.pi-nested-agents-md.installed");

/** The one file name the walk looks for. Pi's own loader also takes
 * `AGENTS.override.md` and `CLAUDE.md`; the shim convention kendex renders
 * puts a directory's instructions in this file, so it is the only one here. */
export const INSTRUCTIONS_FILE = "AGENTS.md";

/** One instructions file the walk reached: `path` is what the session now
 * counts as attached, `text` the block that goes into the read result — the
 * file's content under a line naming it, or the one line saying why there is
 * none. */
export interface Attachment {
	path: string;
	text: string;
}

/** A path with every symlink resolved, or `undefined` where the filesystem
 * cannot answer. The containment test below is a string comparison, so an
 * unresolved path cannot take part in it: a read reached through a symlink
 * must be judged by where it landed, not by how it was spelled. */
function canonical(path: string): string | undefined {
	try {
		return realpathSync(path);
	} catch {
		return undefined;
	}
}

function isFile(path: string): boolean {
	try {
		return statSync(path).isFile();
	} catch {
		return false;
	}
}

/**
 * The directories from `file`'s own up to, not including, `root`, root-most
 * first — the order Claude Code layers nested `CLAUDE.md` files, so a general
 * rule is read before the one that refines it. Both arguments are canonical
 * and `file` lies under `root`; the caller holds that, and this throws rather
 * than walking to the filesystem top if it does not.
 */
export function directoriesBetween(file: string, root: string): string[] {
	const dirs: string[] = [];
	let current = dirname(file);
	while (current !== root) {
		dirs.push(current);
		const parent = dirname(current);
		if (parent === current) {
			throw new Error(`pi-nested-agents-md: ${file} is not under ${root}; the walk was started outside the project`);
		}
		current = parent;
	}
	return dirs.reverse();
}

/** Pi loads a context file from the directory it started in and from every
 * directory above it, so one of those is in the model's context already,
 * whatever this session has attached. */
function loadedByPi(dir: string, cwd: string): boolean {
	return dir === cwd || cwd.startsWith(dir + sep);
}

/**
 * The content of one instructions file as the block that carries it, or the
 * one line that stands in for it. A file the extension cannot read is not a
 * throw: a `read` that succeeded stays succeeded, and the model is told which
 * instructions it did not get.
 */
function block(path: string): string {
	let content: string;
	try {
		content = readFileSync(path, "utf8");
	} catch (error) {
		const reason = error instanceof Error ? error.message : String(error);
		return `[pi-nested-agents-md: ${path} could not be read (${reason.replace(/\s+/g, " ").trim()}); its instructions are not attached]`;
	}
	return `[Directory instructions from ${path}]\n${content}`;
}

/**
 * What one read of `filePath` attaches: every `AGENTS.md` between the file's
 * directory and `root` that Pi did not load at startup and this session has
 * not attached, root-most first. Each is recorded in `attached` as it is
 * taken, the unreadable ones included, so a file is attached — or reported —
 * once per session. Anything the filesystem cannot resolve, and anything
 * resolving outside `root`, attaches nothing: a bound that cannot be checked
 * is not a bound.
 */
export function attachments(filePath: string, cwd: string, root: string, attached: Set<string>): Attachment[] {
	const canonicalRoot = canonical(root);
	const canonicalCwd = canonical(cwd);
	const file = canonical(isAbsolute(filePath) ? filePath : resolve(cwd, filePath));
	if (canonicalRoot === undefined || canonicalCwd === undefined || file === undefined) return [];
	if (!file.startsWith(canonicalRoot + sep)) return [];

	const found: Attachment[] = [];
	for (const dir of directoriesBetween(file, canonicalRoot)) {
		if (loadedByPi(dir, canonicalCwd)) continue;
		const path = join(dir, INSTRUCTIONS_FILE);
		if (attached.has(path) || !isFile(path)) continue;
		attached.add(path);
		found.push({ path, text: block(path) });
	}
	return found;
}

export default function nestedAgentsMd(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;

	// The session's record of what the model has already been handed. A
	// session start of any kind begins it again: the context is empty, or is
	// being rebuilt, and what was attached before is not in it.
	let attached = new Set<string>();

	pi.on("session_start", (_event, ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		attached = new Set<string>();
	});

	pi.on("tool_result", async (event, ctx: ExtensionContext) => {
		if (event.toolName.toLowerCase() !== "read" || event.isError) return undefined;
		const rawPath = (event.input as { path?: unknown })?.path;
		if (typeof rawPath !== "string" || rawPath === "") return undefined;
		if (!Array.isArray(event.content)) return undefined;

		// Resolved once and threaded through: the walk is an ancestor stat per
		// level, and trust, settings and the bound all want the same answer.
		const project = projectRoot(ctx.cwd);
		if (project === undefined) return undefined;
		recordProjectTrust(ctx, project);
		if (!getBool(readConfig(ctx.cwd, project), "enabled")) return undefined;

		const found = attachments(rawPath, ctx.cwd, project, attached);
		if (found.length === 0) return undefined;
		return { content: [...event.content, ...found.map(({ text }) => ({ type: "text" as const, text }))] };
	});
}
