import { existsSync, statSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { homedir } from "node:os";

/**
 * Mirrors `hooks/block-repo-copy.sh`.
 *
 * Refuses a recursive copy (cp -r/-R/-a, recursive or archive rsync, git clone
 * of a local path, tar create-to-extract pipe) when BOTH halves hold: the
 * source carries repository history or a build tree, AND the destination
 * resolves under a temp/scratch root.
 */

/** Directory names whose presence one level inside the source proves the tree is expensive. */
const DANGER_MARKERS = [
	".git",
	"target",
	"node_modules",
	"vendor",
	".venv",
	"venv",
	".next",
	".cache",
	".gradle",
	"Pods",
];

/** Names that are themselves the expensive tree, not merely a container of one. */
const SELF_MARKERS = new Set([".git", "target", "node_modules"]);

/** Cheap pre-filter: no copy verb, no work. */
const COPY_VERB = /(^|[^A-Za-z0-9_-])(cp|rsync|tar)([^A-Za-z0-9_-]|$)|git\s+clone/;

/** A variable reference whose NAME means a temp root; the shell expands it at run time. */
const SCRATCH_VAR = /\$\{?[A-Z_]*(TMP|TEMP|SCRATCH)/;

type Verb = "cp" | "rsync" | "git-clone";

interface Segment {
	verb: Verb;
	recursive: boolean;
	operands: string[];
	/** cp's -t/--target-directory: every operand is a source and this is the destination. */
	target: string;
}

/**
 * Split into tokens honoring quotes, so a path containing a space stays one
 * operand instead of splitting into fragments that resolve to nothing. Command
 * substitutions are kept whole so an inline $(mktemp -d) stays visible.
 */
function tokenize(segment: string): string[] {
	const out: string[] = [];
	let tok = "";
	let quote = "";
	for (let i = 0; i < segment.length; i++) {
		const ch = segment[i];
		if (quote === "'") {
			if (ch === "'") quote = "";
			else tok += ch;
			continue;
		}
		if (quote === '"') {
			if (ch === '"') quote = "";
			else if (ch === "\\" && i + 1 < segment.length) tok += segment[++i];
			else tok += ch;
			continue;
		}
		if (ch === '"' || ch === "'") {
			quote = ch;
			continue;
		}
		if (ch === "\\" && i + 1 < segment.length) {
			tok += segment[++i];
			continue;
		}
		if (ch === "$" && segment[i + 1] === "(") {
			let depth = 1;
			let sub = "$(";
			i += 2;
			for (; i < segment.length && depth > 0; i++) {
				const c = segment[i];
				if (c === "(") depth++;
				else if (c === ")") depth--;
				if (depth > 0) sub += c;
			}
			i--;
			tok += `${sub})`;
			continue;
		}
		if (ch === " " || ch === "\t" || ch === "(" || ch === ")") {
			if (tok) {
				out.push(tok);
				tok = "";
			}
			continue;
		}
		tok += ch;
	}
	if (tok) out.push(tok);
	return out;
}

/**
 * Variables assigned a scratch path earlier in the same command, so a
 * destination written as "$d" is classified by what $d was set to. Reset per
 * evaluated command.
 */
let scratchVars = new Set<string>();

/** The variable a token names, for `$d`, `${d}` and `$d/sub`. */
function varName(raw: string): string {
	if (raw.startsWith("${")) return raw.slice(2).split("}")[0];
	if (raw.startsWith("$")) return raw.slice(1).split("/")[0];
	return "";
}

function collectScratchVars(command: string, cwd: string): Set<string> {
	const names = new Set<string>();
	for (const seg of command.split(/&&|\|\||;|\|/)) {
		for (const tok of tokenize(seg)) {
			const eq = tok.indexOf("=");
			if (eq <= 0) continue;
			const name = tok.slice(0, eq);
			if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) continue;
			const value = tok.slice(eq + 1);
			if (value && isScratch(value, cwd)) names.add(name);
		}
	}
	return names;
}

function expandPath(raw: string, cwd: string): string {
	let p = raw;
	const home = homedir();
	if (p === "~") p = home;
	else if (p.startsWith("~/")) p = join(home, p.slice(2));
	return isAbsolute(p) ? p : resolve(cwd, p);
}

function scratchRoots(): string[] {
	const roots = ["/tmp", "/var/tmp", process.env.TMPDIR ?? "", process.env.CLAUDE_CODE_TMPDIR ?? ""];
	return roots.filter((r) => r.length > 0).map((r) => (r.length > 1 ? r.replace(/\/+$/, "") : r));
}

export function isScratch(raw: string, cwd: string): boolean {
	const lower = raw.toLowerCase();
	if (lower.includes("scratchpad") || lower.includes("mktemp")) return true;
	if (SCRATCH_VAR.test(raw.toUpperCase())) return true;
	const name = varName(raw);
	if (name && scratchVars.has(name)) return true;
	const p = expandPath(raw, cwd);
	return scratchRoots().some((base) => p === base || p.startsWith(`${base}/`));
}

function isDirectory(p: string): boolean {
	try {
		return statSync(p).isDirectory();
	} catch {
		return false;
	}
}

/** The markers that make a source expensive, or an empty array when it has none. */
export function dangerousMarkers(raw: string, cwd: string): string[] {
	const trimmed = raw.length > 1 ? raw.replace(/\/+$/, "") : raw;
	const p = expandPath(trimmed, cwd);
	if (!isDirectory(p)) return [];
	const base = p.slice(p.lastIndexOf("/") + 1);
	if (SELF_MARKERS.has(base)) return [base];
	// `existsSync` only: no traversal, no directory sizing.
	return DANGER_MARKERS.filter((m) => existsSync(join(p, m)));
}

/** A leading `cd` in this segment changes what later relative operands mean. */
function segmentCd(segment: string, cwd: string): string | undefined {
	const toks = tokenize(segment);
	if (toks.length === 0) return undefined;
	if (toks[0].split("/").pop() !== "cd") return undefined;
	const arg = toks[1];
	if (arg === undefined) return homedir();
	if (arg === "-") return undefined;
	return expandPath(arg, cwd);
}

/** Recognize one cp / rsync / git clone invocation, or undefined for anything else. */
export function classifySegment(segment: string): Segment | undefined {
	let verb: Verb | undefined;
	let recursive = false;
	let target = "";
	const operands: string[] = [];
	let pendingGit = false;
	let skipNext = false;
	let wantTarget = false;

	for (const tok of tokenize(segment)) {
		if (skipNext) {
			skipNext = false;
			continue;
		}
		if (wantTarget) {
			target = tok;
			wantTarget = false;
			continue;
		}
		if (verb === undefined) {
			if (pendingGit) {
				if (tok === "clone") {
					verb = "git-clone";
					recursive = true;
				} else if (tok === "-C") {
					skipNext = true;
				} else if (!tok.startsWith("-")) {
					return undefined;
				}
				continue;
			}
			if (tok.includes("=")) continue;
			if (["sudo", "command", "env", "nohup", "time"].includes(tok)) continue;
			const base = tok.split("/").pop() ?? tok;
			if (base === "cp") verb = "cp";
			else if (base === "rsync") verb = "rsync";
			else if (base === "git") pendingGit = true;
			else return undefined;
			continue;
		}

		if (tok === "--recursive" || tok === "--archive") {
			recursive = true;
			continue;
		}
		// cp's -t/--target-directory inverts operand order. rsync's -t is
		// --times, so target parsing is scoped to cp.
		if (verb === "cp" && tok.startsWith("--target-directory=")) {
			target = tok.slice("--target-directory=".length);
			continue;
		}
		if (verb === "cp" && tok === "--target-directory") {
			wantTarget = true;
			continue;
		}
		if (tok.startsWith("--")) continue;
		if (tok.startsWith("-") && tok.length > 1) {
			// Short clusters. rsync's -R is --relative, not recursion.
			if (verb === "cp") {
				if (/[rRa]/.test(tok)) recursive = true;
				const t = tok.indexOf("t", 1);
				if (t === tok.length - 1) wantTarget = true;
				else if (t > 0) target = tok.slice(t + 1);
			} else if (verb === "rsync") {
				if (/[ra]/.test(tok)) recursive = true;
			}
			continue;
		}
		operands.push(tok);
	}

	if (verb === undefined) return undefined;
	return { verb, recursive, operands, target };
}

function countChar(s: string, ch: string): number {
	let n = 0;
	for (const c of s) if (c === ch) n += 1;
	return n;
}

export interface Refusal {
	source: string;
	markers: string[];
	destination: string;
}

function verdict(dest: string, srcs: string[], cwd: string): Refusal | undefined {
	if (!isScratch(dest, cwd)) return undefined;
	for (const src of srcs) {
		if (!src) continue;
		const markers = dangerousMarkers(src, cwd);
		if (markers.length === 0) continue;
		return { source: expandPath(src.replace(/\/+$/, ""), cwd), markers, destination: dest };
	}
	return undefined;
}

function checkCopySegments(command: string, startCwd: string): Refusal | undefined {
	let cwd = startCwd;
	let depth = 0;
	let savedCwd = "";
	let held = false;

	for (const seg of command.split(/&&|\|\||;|\|/)) {
		if (!seg.trim()) continue;
		const opens = countChar(seg, "(");
		const closes = countChar(seg, ")");
		if (depth === 0 && opens > 0 && !held) {
			savedCwd = cwd;
			held = true;
		}
		depth += opens - closes;

		const moved = segmentCd(seg, cwd);
		if (moved !== undefined) cwd = moved;

		const parsed = classifySegment(seg);
		if (parsed && parsed.recursive) {
			let dest = "";
			let srcs: string[] = [];
			if (parsed.target && parsed.operands.length >= 1) {
				dest = parsed.target;
				srcs = parsed.operands;
			} else if (parsed.verb === "git-clone" && parsed.operands.length === 1) {
				dest = cwd;
				srcs = parsed.operands;
			} else if (parsed.operands.length >= 2) {
				dest = parsed.operands[parsed.operands.length - 1];
				srcs = parsed.operands.slice(0, -1);
			}
			if (dest) {
				const refusal = verdict(dest, srcs, cwd);
				if (refusal) return refusal;
			}
		}

		if (depth <= 0) {
			depth = 0;
			if (held) {
				cwd = savedCwd;
				held = false;
			}
		}
	}
	return undefined;
}

interface TarStage {
	mode: "c" | "x";
	dir: string;
	operands: string[];
}

/** One piped tar stage: its mode, its working directory (-C or a leading cd), its operands. */
function tarStage(stage: string): TarStage | undefined {
	let mode: "c" | "x" | "" = "";
	let dir = "";
	const operands: string[] = [];
	let inTar = false;
	let wantDir = false;
	let wantFile = false;
	let wantCd = false;

	for (const tok of tokenize(stage)) {
		if (wantCd) {
			dir = tok;
			wantCd = false;
			continue;
		}
		if (!inTar) {
			const base = tok.split("/").pop() ?? tok;
			if (base === "cd") wantCd = true;
			else if (base === "tar") inTar = true;
			continue;
		}
		if (wantDir) {
			dir = tok;
			wantDir = false;
			continue;
		}
		if (wantFile) {
			wantFile = false;
			continue;
		}
		if (tok === "-C") {
			wantDir = true;
			continue;
		}
		if (tok.startsWith("--directory=")) {
			dir = tok.slice("--directory=".length);
			continue;
		}
		if (tok === "--create") {
			mode = "c";
			continue;
		}
		if (tok === "--extract" || tok === "--get") {
			mode = "x";
			continue;
		}
		if (tok.startsWith("--")) continue;
		if (tok.startsWith("-") && tok.length > 1) {
			if (tok.includes("c")) mode = "c";
			if (tok.includes("x")) mode = "x";
			if (tok.includes("f")) wantFile = true;
			continue;
		}
		// Old-style bundled flags carry no leading dash.
		if (!mode && /^[cxtrudA]/.test(tok) && /^[cxvfzjJtC]+$/.test(tok)) {
			if (tok.includes("c")) mode = "c";
			if (tok.includes("x")) mode = "x";
			if (tok.includes("f")) wantFile = true;
			continue;
		}
		operands.push(tok);
	}

	if (!mode) return undefined;
	return { mode, dir, operands };
}

function checkTarPipe(command: string, cwd: string): Refusal | undefined {
	if (!command.includes("|")) return undefined;
	let srcs: string[] = [];
	let srcDir = "";
	let dest = "";

	for (const stage of command.split(/\|\||\|/)) {
		if (!stage.trim()) continue;
		const parsed = tarStage(stage);
		if (!parsed) continue;
		if (parsed.mode === "c") {
			srcDir = parsed.dir;
			srcs = parsed.operands;
		} else {
			dest = parsed.dir || cwd;
		}
	}

	if ((srcs.length === 0 && !srcDir) || !dest) return undefined;
	if (srcDir) {
		srcs = srcs.length === 0
			? [srcDir]
			: srcs.map((s) => (isAbsolute(s) || s.startsWith("~") ? s : join(srcDir, s)));
	}
	return verdict(dest, srcs, cwd);
}

export function repoCopyRefusal(command: string, cwd: string): Refusal | undefined {
	if (!COPY_VERB.test(command)) return undefined;
	scratchVars = new Set();
	scratchVars = collectScratchVars(command, cwd);
	return checkTarPipe(command, cwd) ?? checkCopySegments(command, cwd);
}

export function refusalReason(command: string, refusal: Refusal): string {
	return [
		"Refusing a recursive copy of an expensive tree into scratch space.",
		`  command:     ${command}`,
		`  source:      ${refusal.source} (contains ${refusal.markers.join(", ")})`,
		`  destination: ${refusal.destination} (temp/scratch)`,
		"",
		"A source carrying repository history or a build tree is large by construction,",
		"and temp/scratch filesystems are commonly RAM-backed tmpfs — the copy can fill",
		"the filesystem, after which every process writing there fails with ENOSPC.",
		"",
		"Do one of these instead:",
		"  - Read the source in place. Reading does not mutate it, so no copy is needed",
		"    to leave it unchanged.",
		"  - Build a MINIMAL synthetic fixture:",
		'      d=$(mktemp -d); mkdir -p "$d/repo/.git" "$d/repo/target"; touch "$d/repo/f"',
	].join("\n");
}
