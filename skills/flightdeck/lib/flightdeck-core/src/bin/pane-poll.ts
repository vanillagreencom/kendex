#!/usr/bin/env bun
// CLI parity port of skills/flightdeck/scripts/pane-poll.
//
// Single-pane mode emits one JSON object on stdout. Batch mode reads a
// JSON array from stdin (or a file/inline JSON arg) and emits one JSON
// object per row.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { classifyBuffer } from "../classifier/classify.ts";
import { OC_LAST_ASSISTANT_JQ, ocAdapterIsFresh, ocIssueFromPaneTarget, ocSpawnFile } from "../paths/oc.ts";
import { CC_LAST_ASSISTANT_JQ, ccAdapterIsFresh, ccSpawnFile } from "../paths/cc.ts";
import { PI_LAST_ASSISTANT_JQ, piBridgeIsFresh, piResolveBridgeBin, piSpawnFile } from "../paths/pi.ts";
import { CX_LAST_ASSISTANT_JQ, cxAdapterIsFresh, cxBridgeRun, cxSpawnFile } from "../paths/codex.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const PANE_REGISTRY_SCRIPT = resolve(HERE, "../../../../scripts/pane-registry");

function die(msg: string, code = 2): never {
	process.stderr.write(`${msg}\n`);
	process.exit(code);
}

if (!process.env.TMUX) die("Error: not inside a tmux session");

const CAPTURE_ARGS = ["-p", "-S", "-200"];

// Fingerprint sentinel — hoisted to module-level so it isn't recompiled
// per pollOne call (reviewer-perf nice-to-have).
const FINGERPRINT_SENTINEL = /❯ |claude code|opencode|codex>|■■■|⠋|⠙|⠸|⠴|⠦|⠧/;

interface PaneMeta {
	window: string;
	listTarget: string;
	index: string;
	bell: string;
	activity: string;
	silence: string;
}

const META: Map<string, PaneMeta> = new Map();
const PANE_ID_BY_TARGET: Map<string, string> = new Map();

function refreshTmuxMetadata(): void {
	META.clear();
	PANE_ID_BY_TARGET.clear();
	const r = spawnSync("tmux", [
		"list-panes", "-a",
		"-F", "#{pane_id}\t#{session_name}\t#{window_name}\t#{window_id}\t#{pane_index}\t#{window_bell_flag}\t#{window_activity_flag}\t#{window_silence_flag}",
	], { encoding: "utf8" });
	if (r.status !== 0) return;
	for (const line of (r.stdout ?? "").split("\n")) {
		if (!line) continue;
		const [pid, sess, wname, wid, pidx, bell, activity, silence] = line.split("\t");
		if (!pid || !pid.startsWith("%")) continue;
		const window = `${sess ?? ""}:${wname ?? ""}`;
		const humanTarget = `${window}.${pidx ?? "0"}`;
		META.set(pid, {
			activity: activity ?? "0",
			bell: bell ?? "0",
			index: pidx ?? "0",
			listTarget: wid || window,
			silence: silence ?? "0",
			window,
		});
		PANE_ID_BY_TARGET.set(humanTarget, pid);
	}
}

function jqOut(filter: string, input: string, raw = true): string {
	const args = raw ? ["-r", filter] : [filter];
	const r = spawnSync("jq", args, { encoding: "utf8", input });
	if (r.status !== 0) return "";
	return (r.stdout ?? "").replace(/\n$/, "");
}

function jqFileOut(filter: string, file: string, raw = true): string {
	const args = raw ? ["-r", filter, file] : [filter, file];
	const r = spawnSync("jq", args, { encoding: "utf8" });
	if (r.status !== 0) return "";
	return (r.stdout ?? "").replace(/\n$/, "");
}

// Memoized `gh` PATH probe. Cached for the lifetime of the pane-poll
// process so a single batch invocation doesn't pay one `command -v`
// fork per row.
let _ghAvailable: boolean | undefined;
function ghAvailable(): boolean {
	if (_ghAvailable !== undefined) return _ghAvailable;
	const r = spawnSync("bash", ["-c", "command -v gh >/dev/null 2>&1"]);
	_ghAvailable = r.status === 0;
	return _ghAvailable;
}

function jsonDead(issue: string, window: string, pane: string): string {
	const out: Record<string, unknown> = { dead: true, pane_target: pane, tag: "dead", window };
	if (issue) out.issue = issue;
	// Reorder for parity with bash: issue first when present.
	const ordered: Record<string, unknown> = {};
	if (issue) ordered.issue = issue;
	ordered.window = window;
	ordered.pane_target = pane;
	ordered.dead = true;
	ordered.tag = "dead";
	return JSON.stringify(ordered);
}

function jsonResult(
	issue: string, window: string, pane: string,
	bell: string, activity: string, silence: string,
	tag: string, captureHash: string,
	fingerprintMatch: boolean, paneIndexSuggest: number | null,
): string {
	const obj: Record<string, unknown> = {};
	if (issue) obj.issue = issue;
	obj.window = window;
	obj.pane_target = pane;
	obj.bell = bell === "1";
	obj.activity = activity === "1";
	obj.silence = silence === "1";
	obj.tag = tag;
	obj.capture_hash = captureHash;
	obj.fingerprint_match = fingerprintMatch;
	obj.pane_index_suggest = paneIndexSuggest;
	return JSON.stringify(obj);
}

function splitTargetAndIndex(raw: string, explicit: string): { windowTarget: string; paneTarget: string; paneIndex: string } {
	if (explicit) return { paneIndex: explicit, paneTarget: `${raw}.${explicit}`, windowTarget: raw };
	const m = raw.match(/^(.+)\.([0-9]+)$/);
	if (m) return { paneIndex: m[2]!, paneTarget: raw, windowTarget: m[1]! };
	return { paneIndex: "0", paneTarget: `${raw}.0`, windowTarget: raw };
}

function registryIssueForPane(issue: string, paneLookup: string): string {
	if (issue) return issue;
	const r = spawnSync(PANE_REGISTRY_SCRIPT, ["find-by-pane", paneLookup], { encoding: "utf8" });
	if (r.status !== 0) return "";
	const raw = (r.stdout ?? "").trim();
	if (!raw.startsWith("{")) return raw;
	try {
		const parsed = JSON.parse(raw) as { id?: unknown };
		return typeof parsed.id === "string" ? parsed.id : "";
	} catch {
		return "";
	}
}

function paneRegistryArgs(action: string, issue: string): string {
	const r = spawnSync(PANE_REGISTRY_SCRIPT, [action, issue], { encoding: "utf8" });
	if (r.status !== 0) return "";
	return (r.stdout ?? "").trim();
}

// ---- adapter args resolution ----------------------------------------------

function resolveOcArgs(issue: string, paneLookup: string, deriveTarget: string, rowUrl: string, rowSid: string, fromBatch: boolean): string {
	const adapterIssue = registryIssueForPane(issue, paneLookup);
	if (adapterIssue && rowUrl && rowSid) {
		if (ocAdapterIsFresh(adapterIssue)) return `--url ${rowUrl} --session ${rowSid}`;
	} else if (adapterIssue && !fromBatch) {
		const args = paneRegistryArgs("oc-attach-args", adapterIssue);
		if (args) return args;
	}
	const derived = ocIssueFromPaneTarget(deriveTarget);
	if (!derived) return "";
	const spawn = ocSpawnFile(derived);
	if (!existsSync(spawn)) return "";
	if (!ocAdapterIsFresh(derived)) return "";
	let rec: Record<string, unknown> = {};
	try { rec = JSON.parse(readFileSync(spawn, "utf8")); } catch { /* */ }
	const url = String(rec.url ?? "");
	const sid = String(rec.session_id ?? "");
	if (!url || !sid) return "";
	return `--url ${url} --session ${sid}`;
}

function resolveCcArgs(issue: string, paneLookup: string, deriveTarget: string, rowUrl: string, rowTranscript: string, fromBatch: boolean): string {
	const adapterIssue = registryIssueForPane(issue, paneLookup);
	if (adapterIssue && rowUrl && rowTranscript) {
		if (ccAdapterIsFresh(adapterIssue)) return `--url ${rowUrl} --transcript ${rowTranscript}`;
	} else if (adapterIssue && !fromBatch) {
		const args = paneRegistryArgs("cc-channel-args", adapterIssue);
		if (args) return args;
	}
	const derived = ocIssueFromPaneTarget(deriveTarget);
	if (!derived) return "";
	const spawn = ccSpawnFile(derived);
	if (!existsSync(spawn)) return "";
	if (!ccAdapterIsFresh(derived)) return "";
	let rec: Record<string, unknown> = {};
	try { rec = JSON.parse(readFileSync(spawn, "utf8")); } catch { /* */ }
	const url = String(rec.url ?? "");
	const transcript = String(rec.transcript ?? "");
	if (!url || !transcript) return "";
	return `--url ${url} --transcript ${transcript}`;
}

function resolvePiArgs(issue: string, paneLookup: string, deriveTarget: string, rowPid: string, rowSocket: string, fromBatch: boolean): string {
	const adapterIssue = registryIssueForPane(issue, paneLookup);
	if (adapterIssue && rowPid && rowSocket) {
		if (piBridgeIsFresh(Number(rowPid), rowSocket)) return `--pid ${rowPid} --socket ${rowSocket}`;
	} else if (adapterIssue && !fromBatch) {
		const args = paneRegistryArgs("pi-bridge-args", adapterIssue);
		if (args) return args;
	}
	const derived = ocIssueFromPaneTarget(deriveTarget);
	if (!derived) return "";
	const spawn = piSpawnFile(derived);
	if (!existsSync(spawn)) return "";
	let rec: Record<string, unknown> = {};
	try { rec = JSON.parse(readFileSync(spawn, "utf8")); } catch { /* */ }
	const pid = String(rec.pid ?? "");
	const socket = String(rec.socket ?? "");
	if (!pid || !socket) return "";
	if (!piBridgeIsFresh(Number(pid), socket)) return "";
	return `--pid ${pid} --socket ${socket}`;
}

function resolveCxArgs(issue: string, paneLookup: string, deriveTarget: string, rowUrl: string, rowThread: string, fromBatch: boolean): string {
	const adapterIssue = registryIssueForPane(issue, paneLookup);
	if (adapterIssue && rowUrl && rowThread) {
		if (cxAdapterIsFresh(adapterIssue)) return `--url ${rowUrl} --thread ${rowThread}`;
	} else if (adapterIssue && !fromBatch) {
		const args = paneRegistryArgs("cx-bridge-args", adapterIssue);
		if (args) return args;
	}
	const derived = ocIssueFromPaneTarget(deriveTarget);
	if (!derived) return "";
	const spawn = cxSpawnFile(derived);
	if (!existsSync(spawn)) return "";
	if (!cxAdapterIsFresh(derived)) return "";
	let rec: Record<string, unknown> = {};
	try { rec = JSON.parse(readFileSync(spawn, "utf8")); } catch { /* */ }
	const url = String(rec.url ?? "");
	const thread = String(rec.thread_id ?? "");
	if (!url || !thread) return "";
	return `--url ${url} --thread ${thread}`;
}

function extractFlag(s: string, flag: string): string {
	const m = s.match(new RegExp(`${flag}\\s+(\\S+)`));
	return m ? m[1]! : "";
}

// ---- poll ----------------------------------------------------------------

interface PollRow {
	issue: string;
	rawTarget: string;
	explicitIndex: string;
	harness: string;
	worktree: string;
	pr: string;
	ocUrl: string; ocSession: string;
	ccUrl: string; ccTranscript: string;
	piPid: string; piSocket: string;
	cxUrl: string; cxThread: string;
	fromBatch: boolean;
}

function pollOne(row: PollRow): string {
	const { issue, rawTarget, explicitIndex, harness, worktree, pr, fromBatch } = row;
	if (!rawTarget || rawTarget === "null") return jsonDead(issue, "", "");

	let pid: string;
	let outputPane: string;
	let windowTarget: string;
	let windowListTarget: string;
	let paneIndex: string;
	let bell = "0", activity = "0", silence = "0";

	if (rawTarget.startsWith("%")) {
		pid = rawTarget;
		outputPane = pid;
		const m = META.get(pid);
		if (!m) return jsonDead(issue, rawTarget, outputPane);
		windowTarget = m.window;
		windowListTarget = m.listTarget;
		paneIndex = m.index;
		bell = m.bell; activity = m.activity; silence = m.silence;
	} else {
		const split = splitTargetAndIndex(rawTarget, explicitIndex);
		windowTarget = split.windowTarget;
		outputPane = split.paneTarget;
		paneIndex = split.paneIndex;
		const lookup = PANE_ID_BY_TARGET.get(outputPane);
		if (!lookup) return jsonDead(issue, windowTarget, outputPane);
		pid = lookup;
		const m = META.get(pid);
		if (m) {
			windowTarget = m.window || windowTarget;
			windowListTarget = m.listTarget;
			paneIndex = m.index || paneIndex;
			bell = m.bell; activity = m.activity; silence = m.silence;
		} else {
			windowListTarget = windowTarget;
		}
	}
	const deriveTarget = `${windowTarget}.${paneIndex}`;

	let buf = "";
	let ocUsed = false, ccUsed = false, piUsed = false, cxUsed = false;

	// Per-adapter read timeout. Each subprocess is bounded so one stale
	// adapter cannot exceed the daemon's FD_POLL_SEC tick. Configurable
	// via FD_ADAPTER_READ_TIMEOUT_SEC (default 2). Sub-second values
	// are honored — the env is parsed as float, then converted to
	// ceil(ms) for spawn timeouts. curl gets the raw seconds string
	// via --max-time which supports fractional values natively.
	const adapterTimeout = process.env.FD_ADAPTER_READ_TIMEOUT_SEC ?? "2";
	function adapterTimeoutMs(): number {
		const parsed = Number.parseFloat(adapterTimeout);
		if (!Number.isFinite(parsed) || parsed <= 0) return 2000;
		return Math.ceil(parsed * 1000);
	}
	// Adapter contract: if the adapter has fresh args AND the read
	// succeeds (status 0, non-empty stdout, non-empty extracted buf),
	// mark *Used so the tmux fallback below is skipped. If the read
	// fails or returns empty, leave *Used false so the tmux fallback
	// engages. The previous code set *Used unconditionally on fresh
	// args, which meant a curl timeout / dead pi-bridge / unreachable
	// codex-bridge silently produced an empty buffer and the classifier
	// returned `idle` despite the pane being alive.
	if (harness === "opencode") {
		const args = resolveOcArgs(issue, outputPane, deriveTarget, row.ocUrl, row.ocSession, fromBatch);
		if (args) {
			const url = extractFlag(args, "--url");
			const sid = extractFlag(args, "--session");
			const r = spawnSync("curl", ["-s", "--max-time", adapterTimeout, `${url}/session/${sid}/message`], { encoding: "utf8" });
			if (r.status === 0 && r.stdout) {
				const extracted = jqOut(OC_LAST_ASSISTANT_JQ, r.stdout);
				if (extracted) { buf = extracted; ocUsed = true; }
			}
		}
	}
	if (harness === "claude" && !ocUsed) {
		const args = resolveCcArgs(issue, outputPane, deriveTarget, row.ccUrl, row.ccTranscript, fromBatch);
		if (args) {
			const transcript = extractFlag(args, "--transcript");
			if (transcript && existsSync(transcript)) {
				const extracted = jqFileOut(CC_LAST_ASSISTANT_JQ, transcript);
				if (extracted) { buf = extracted; ccUsed = true; }
			}
		}
	}
	if (harness === "pi" && !ocUsed && !ccUsed) {
		const args = resolvePiArgs(issue, outputPane, deriveTarget, row.piPid, row.piSocket, fromBatch);
		if (args) {
			const piSocket = extractFlag(args, "--socket");
			const piPid = extractFlag(args, "--pid");
			const bin = piResolveBridgeBin();
			if (bin) {
				const target = piSocket ? ["--socket", piSocket] : ["--pid", piPid];
				// Bound the bridge call so a hung pi-bridge cannot dominate
				// the tick. pi-bridge has no --timeout flag, so we use
				// spawnSync's built-in `timeout` option — same semantics as
				// timeout(1) (SIGTERM after the deadline) but in-process,
				// dropping one fork per Pi pane per tick.
				const r = spawnSync(bin, ["history", ...target, "50"], { encoding: "utf8", timeout: adapterTimeoutMs() });
				if (r.status === 0 && r.stdout) {
					const extracted = jqOut(PI_LAST_ASSISTANT_JQ, r.stdout);
					if (extracted) { buf = extracted; piUsed = true; }
				}
			}
		}
	}
	if (harness === "codex" && !ocUsed && !ccUsed && !piUsed) {
		const args = resolveCxArgs(issue, outputPane, deriveTarget, row.cxUrl, row.cxThread, fromBatch);
		if (args) {
			const url = extractFlag(args, "--url");
			const thread = extractFlag(args, "--thread");
			// codex-bridge respects FD_CODEX_RPC_TIMEOUT_MS — mirror our
			// adapter timeout for parity with the other reads.
			const prev = process.env.FD_CODEX_RPC_TIMEOUT_MS;
			process.env.FD_CODEX_RPC_TIMEOUT_MS = String(adapterTimeoutMs());
			const r = cxBridgeRun(["turns", "--url", url, "--thread", thread]);
			if (prev !== undefined) process.env.FD_CODEX_RPC_TIMEOUT_MS = prev;
			else delete process.env.FD_CODEX_RPC_TIMEOUT_MS;
			if (r.status === 0 && r.stdout) {
				const extracted = jqOut(CX_LAST_ASSISTANT_JQ, r.stdout);
				if (extracted) { buf = extracted; cxUsed = true; }
			}
		}
	}

	const adapterUsed = ocUsed || ccUsed || piUsed || cxUsed;

	if (!adapterUsed) {
		const r = spawnSync("tmux", ["capture-pane", "-t", outputPane, ...CAPTURE_ARGS], { encoding: "utf8" });
		if (r.status !== 0) {
			const exists = spawnSync("tmux", ["list-panes", "-t", outputPane], { encoding: "utf8" });
			if (exists.status !== 0) return jsonDead(issue, windowTarget, outputPane);
			buf = "";
		} else {
			buf = r.stdout ?? "";
		}
	}

	const captureHash = `sha256:${createHash("sha256").update(buf).digest("hex")}`;
	const classifyResult = classifyBuffer(buf, { noFooterGate: adapterUsed });
	let tag = classifyResult.tag;

	if (tag !== "terminal-state-reached" && worktree && worktree !== "null" && pr && pr !== "null") {
		if (!existsSync(worktree)) {
			// Gate on `gh` availability and bound the call so a slow GitHub
			// response cannot stall the tick (reviewer-perf finding).
			// Cache the gh probe per process: a full batch (one pane-poll
			// invocation, N panes) was paying one bash + command-v fork
			// per missing-worktree pane.
			if (ghAvailable()) {
				const r = spawnSync("gh", ["pr", "view", pr, "--json", "state", "--jq", ".state"], { encoding: "utf8", timeout: adapterTimeoutMs() });
				if (r.status === 0 && (r.stdout ?? "").trim() === "MERGED") tag = "terminal-state-reached";
			}
		}
	}

	let fingerprintMatch = true;
	let paneIndexSuggest: number | null = null;
	if (!adapterUsed) {
		if (!FINGERPRINT_SENTINEL.test(buf)) {
			fingerprintMatch = false;
			const r = spawnSync("tmux", ["list-panes", "-t", windowListTarget, "-F", "#{pane_index}\t#{pane_id}"], { encoding: "utf8" });
			if (r.status === 0) {
				for (const line of (r.stdout ?? "").split("\n")) {
					if (!line) continue;
					const [idx, sibPaneId] = line.split("\t");
					if (!idx || idx === paneIndex || sibPaneId === outputPane) continue;
					const sib = spawnSync("tmux", ["capture-pane", "-t", sibPaneId!, "-p", "-S", "-50"], { encoding: "utf8" });
					if (sib.status === 0 && FINGERPRINT_SENTINEL.test(sib.stdout ?? "")) {
						paneIndexSuggest = Number.parseInt(idx, 10);
						break;
					}
				}
			}
		}
	}

	return jsonResult(issue, windowTarget, outputPane, bell, activity, silence, tag, captureHash, fingerprintMatch, paneIndexSuggest);
}

// ---- main ---------------------------------------------------------------

function usage(code = 2): never {
	process.stderr.write("Usage:\n  pane-poll <window-target|%pane_id> [<pane-index>] [--harness <h>] [--worktree <path>] [--pr <N>]\n  pane-poll --batch -\n  pane-poll --batch <json-or-file>\n");
	process.exit(code);
}

const argv = process.argv.slice(2);
if (argv[0] === "-h" || argv[0] === "--help") usage(0);

if (argv[0] === "--batch") {
	argv.shift();
	if (argv.length !== 1) usage();
	const src = argv[0]!;
	let raw = "";
	if ((src as string) === "-") {
		const buf: Buffer[] = [];
		for await (const ch of process.stdin) buf.push(ch as Buffer);
		raw = Buffer.concat(buf).toString("utf8");
	} else if (existsSync(src) && statSync(src).isFile()) {
		raw = readFileSync(src, "utf8");
	} else {
		raw = src;
	}
	let arr: unknown[];
	try { arr = JSON.parse(raw); } catch { die("Error: --batch input must be a JSON array"); }
	if (!Array.isArray(arr)) die("Error: --batch input must be a JSON array");
	refreshTmuxMetadata();
	for (const rec of arr as Array<Record<string, unknown>>) {
		const row: PollRow = {
			ccTranscript: String(rec.cc_transcript ?? ""),
			ccUrl: String(rec.cc_url ?? ""),
			cxThread: String(rec.cx_thread_id ?? ""),
			cxUrl: String(rec.cx_ws ?? ""),
			explicitIndex: "",
			fromBatch: true,
			harness: String(rec.harness ?? ""),
			issue: String(rec.issue ?? ""),
			ocSession: String(rec.oc_session_id ?? ""),
			ocUrl: String(rec.oc_url ?? ""),
			piPid: rec.pi_bridge_pid != null ? String(rec.pi_bridge_pid) : "",
			piSocket: String(rec.pi_bridge_socket ?? ""),
			pr: rec.pr_number != null ? String(rec.pr_number) : "",
			rawTarget: String(rec.pane_id ?? "") || String(rec.pane_target ?? ""),
			worktree: String(rec.worktree ?? ""),
		};
		if (!row.issue && !row.rawTarget) continue;
		process.stdout.write(`${pollOne(row)}\n`);
	}
	process.exit(0);
}

let target = argv.shift();
if (!target) usage();
let paneIndex = "0";
let harness = "", worktree = "", pr = "";
if (argv.length > 0 && !argv[0]!.startsWith("--") && !target!.startsWith("%")) {
	paneIndex = argv.shift()!;
}
while (argv.length > 0) {
	const a = argv.shift()!;
	if (a === "--harness") harness = argv.shift() ?? "";
	else if (a.startsWith("--harness=")) harness = a.slice("--harness=".length);
	else if (a === "--worktree") worktree = argv.shift() ?? "";
	else if (a.startsWith("--worktree=")) worktree = a.slice("--worktree=".length);
	else if (a === "--pr") pr = argv.shift() ?? "";
	else if (a.startsWith("--pr=")) pr = a.slice("--pr=".length);
	else if (a === "-h" || a === "--help") usage(0);
}

refreshTmuxMetadata();
process.stdout.write(`${pollOne({
	ccTranscript: "", ccUrl: "",
	cxThread: "", cxUrl: "",
	explicitIndex: paneIndex,
	fromBatch: false,
	harness, issue: "",
	ocSession: "", ocUrl: "",
	piPid: "", piSocket: "",
	pr,
	rawTarget: target!,
	worktree,
})}\n`);
