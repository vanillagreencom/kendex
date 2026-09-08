import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { actionSummary, parseApplyPatch, type ParsedPatch, type PatchAction, type PatchHunk } from "./parser.js";

export interface ApplyPatchOptions {
	cwd: string;
	allowAbsolutePaths?: boolean;
}

export interface AppliedPatchFile {
	kind: PatchAction["kind"];
	path: string;
	absolutePath: string;
	moveTo?: string;
	absoluteMoveTo?: string;
}

export interface ApplyPatchResult {
	files: AppliedPatchFile[];
	summary: string;
}

function cleanPatchPath(pathValue: string): string {
	let cleaned = pathValue.trim();
	if ((cleaned.startsWith('"') && cleaned.endsWith('"')) || (cleaned.startsWith("'") && cleaned.endsWith("'"))) cleaned = cleaned.slice(1, -1);
	if (cleaned.startsWith("@")) cleaned = cleaned.slice(1);
	return cleaned;
}

export function resolvePatchPath(pathValue: string, options: ApplyPatchOptions): string {
	const cleaned = cleanPatchPath(pathValue);
	const absolute = isAbsolute(cleaned) ? resolve(cleaned) : resolve(options.cwd, cleaned);
	const cwd = resolve(options.cwd);
	const rel = relative(cwd, absolute);
	const insideCwd = rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
	if (!insideCwd && !options.allowAbsolutePaths) throw Object.assign(new Error(`patch_path_outside=${pathValue}\nPatch path escapes cwd: ${pathValue}`), { code: "PATCH_PATH_OUTSIDE", path: pathValue });
	return absolute;
}

function stripMarker(line: string): string {
	if (line === "\\ No newline at end of file") return "";
	const marker = line[0];
	return marker === "+" || marker === "-" || marker === " " ? line.slice(1) : line;
}

function hunkOldText(hunk: PatchHunk): string {
	return hunk.lines.filter((line) => line.startsWith("-") || line.startsWith(" ")).map(stripMarker).join("\n");
}

function hunkNewText(hunk: PatchHunk): string {
	return hunk.lines.filter((line) => line.startsWith("+") || line.startsWith(" ")).map(stripMarker).join("\n");
}

function addText(action: PatchAction): string {
	return action.hunks.flatMap((hunk) => hunk.lines.filter((line) => line.startsWith("+")).map(stripMarker)).join("\n");
}

interface FileSnapshot {
	absolutePath: string;
	existed: boolean;
	data?: Buffer;
}

async function snapshotPath(absolutePath: string): Promise<FileSnapshot> {
	try {
		return { absolutePath, existed: true, data: await readFile(absolutePath) };
	} catch {
		return { absolutePath, existed: false };
	}
}

async function restoreSnapshots(snapshots: FileSnapshot[]): Promise<void> {
	for (const snapshot of [...snapshots].reverse()) {
		if (snapshot.existed) {
			await mkdir(dirname(snapshot.absolutePath), { recursive: true });
			await writeFile(snapshot.absolutePath, snapshot.data ?? Buffer.alloc(0));
		} else if (existsSync(snapshot.absolutePath)) {
			await rm(snapshot.absolutePath, { force: true, recursive: true });
		}
	}
}

async function readUtf8(path: string): Promise<string> {
	try {
		return await readFile(path, "utf8");
	} catch (error) {
		throw Object.assign(new Error(`patch_read_failed=${path}\nFailed to read ${path}: ${error instanceof Error ? error.message : String(error)}`, { cause: error }), { code: "PATCH_READ_FAILED", path });
	}
}

function replaceUnique(content: string, oldText: string, newText: string, path: string): string | undefined {
	const first = content.indexOf(oldText);
	if (first < 0) return undefined;
	if (content.indexOf(oldText, first + oldText.length) >= 0) throw Object.assign(new Error(`patch_context_ambiguous=${path}\nPatch context is ambiguous in ${path}`), { code: "PATCH_CONTEXT_AMBIGUOUS", path });
	return `${content.slice(0, first)}${newText}${content.slice(first + oldText.length)}`;
}

function replaceOnce(content: string, oldText: string, newText: string, path: string): string {
	if (oldText.length === 0) return `${content}${newText}`;
	const candidates: Array<[string, string]> = [[oldText, newText]];
	if (!oldText.endsWith("\n")) candidates.push([`${oldText}\n`, newText]);
	const crlfOld = oldText.replace(/\n/g, "\r\n");
	const crlfNew = newText.replace(/\n/g, "\r\n");
	candidates.push([crlfOld, crlfNew]);
	if (!crlfOld.endsWith("\r\n")) candidates.push([`${crlfOld}\r\n`, crlfNew]);
	for (const [candidateOld, candidateNew] of candidates) {
		const next = replaceUnique(content, candidateOld, candidateNew, path);
		if (next !== undefined) return next;
	}
	throw new Error(`Patch context not found in ${path}`);
}

async function applyAdd(action: PatchAction, options: ApplyPatchOptions): Promise<AppliedPatchFile> {
	const absolutePath = resolvePatchPath(action.path, options);
	const content = addText(action);
	await mkdir(dirname(absolutePath), { recursive: true });
	await writeFile(absolutePath, content, "utf8");
	return { absolutePath, kind: action.kind, path: action.path };
}

async function applyUpdate(action: PatchAction, options: ApplyPatchOptions): Promise<AppliedPatchFile> {
	const absolutePath = resolvePatchPath(action.path, options);
	let content = await readUtf8(absolutePath);
	for (const hunk of action.hunks) content = replaceOnce(content, hunkOldText(hunk), hunkNewText(hunk), action.path);
	await writeFile(absolutePath, content, "utf8");
	let absoluteMoveTo: string | undefined;
	if (action.moveTo) {
		absoluteMoveTo = resolvePatchPath(action.moveTo, options);
		await mkdir(dirname(absoluteMoveTo), { recursive: true });
		await rename(absolutePath, absoluteMoveTo);
	}
	return { absoluteMoveTo, absolutePath, kind: action.kind, moveTo: action.moveTo, path: action.path };
}

async function applyDelete(action: PatchAction, options: ApplyPatchOptions): Promise<AppliedPatchFile> {
	const absolutePath = resolvePatchPath(action.path, options);
	await rm(absolutePath, { force: false });
	return { absolutePath, kind: action.kind, path: action.path };
}

export async function applyParsedPatch(parsed: ParsedPatch, options: ApplyPatchOptions): Promise<ApplyPatchResult> {
	const files: AppliedPatchFile[] = [];
	const snapshots = new Map<string, FileSnapshot>();
	const snapshotAction = async (action: PatchAction) => {
		for (const pathValue of [action.path, action.moveTo].filter((value): value is string => Boolean(value))) {
			const absolutePath = resolvePatchPath(pathValue, options);
			if (!snapshots.has(absolutePath)) snapshots.set(absolutePath, await snapshotPath(absolutePath));
		}
	};
	try {
		for (const action of parsed.actions) {
			await snapshotAction(action);
			if (action.kind === "add") files.push(await applyAdd(action, options));
			else if (action.kind === "update") files.push(await applyUpdate(action, options));
			else files.push(await applyDelete(action, options));
		}
	} catch (error) {
		const applied = files.map((file) => `${file.kind} ${file.path}`).join(", ") || "none";
		const message = error instanceof Error ? error.message : String(error);
		await restoreSnapshots([...snapshots.values()]);
		throw Object.assign(new Error(`${message}\nPartial apply status: completed actions before failure: ${applied}. Rolled back touched files; review the working tree before retrying.`, { cause: error }), error instanceof Error ? { code: (error as NodeJS.ErrnoException).code, path: (error as NodeJS.ErrnoException).path } : {});
	}
	return {
		files,
		summary: `Applied patch: ${parsed.actions.map(actionSummary).join(", ")}`,
	};
}

export async function applyPatch(input: string, options: ApplyPatchOptions): Promise<ApplyPatchResult> {
	return applyParsedPatch(parseApplyPatch(input), options);
}
