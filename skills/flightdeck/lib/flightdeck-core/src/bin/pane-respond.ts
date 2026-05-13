#!/usr/bin/env bun
// CLI parity port of skills/flightdeck/scripts/pane-respond.
//
// 5-harness protocol switch: claude / opencode / pi / codex / tmux-fallback.
// Modes: payload (free text), --option N, --option-multi N1,N2,..., --keys,
// --question <reqID> --answer/--answer-multi/--answer-text/--answers-json/--reject.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ocAttachArgsFromSpawn, ocIssueFromPaneTarget, ocSpawnFile } from "../paths/oc.ts";
import { ccSpawnFile } from "../paths/cc.ts";
import { piBridgeIsFresh, piResolveBridgeBin, piSpawnFile } from "../paths/pi.ts";
import { cxBridgeRun, cxSpawnFile } from "../paths/codex.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const PANE_REGISTRY = resolve(HERE, "../../../../scripts/pane-registry");
const PANE_CLEAR_BELL = resolve(HERE, "../../../../scripts/pane-clear-bell");

function die(msg: string, code = 2): never {
	process.stderr.write(`${msg}\n`);
	process.exit(code);
}

if (!process.env.TMUX) die("Error: not inside a tmux session");

interface Args {
	target: string;
	payload: string;
	mode: "payload" | "option" | "option-multi" | "keys" | "question";
	optionN: string;
	optionMultiCsv: string;
	keysCsv: string;
	tag: string;
	harness: string;
	sendEnter: boolean;
	clearBell: boolean;
	keysAllowTmux: boolean;
	confirmAdvanced: boolean;
	questionId: string;
	answerLabel: string;
	answerMultiCsv: string;
	answerText: string;
	answersJson: string;
	rejectQuestion: boolean;
}

function parseArgs(): Args {
	const a = process.argv.slice(2);
	const target = a.shift();
	if (!target) die("Usage: pane-respond <pane-target> <payload>|--option N|--keys k1,k2,... [flags]");
	const args: Args = {
		answerLabel: "",
		answerMultiCsv: "",
		answerText: "",
		answersJson: "",
		clearBell: true,
		confirmAdvanced: false,
		harness: "claude",
		keysAllowTmux: false,
		keysCsv: "",
		mode: "payload",
		optionMultiCsv: "",
		optionN: "",
		payload: "",
		questionId: "",
		rejectQuestion: false,
		sendEnter: true,
		tag: "",
		target: target!,
	};
	if (a.length > 0 && !a[0]!.startsWith("--")) {
		args.payload = a.shift()!;
	}
	while (a.length > 0) {
		const cur = a.shift()!;
		const eq = cur.indexOf("=");
		const flag = eq >= 0 ? cur.slice(0, eq) : cur;
		const inlineVal = eq >= 0 ? cur.slice(eq + 1) : "";
		const next = () => inlineVal || (a.shift() ?? "");
		switch (flag) {
			case "--option":       args.mode = "option"; args.optionN = next(); break;
			case "--option-multi": args.mode = "option-multi"; args.optionMultiCsv = next(); break;
			case "--keys":         args.mode = "keys"; args.keysCsv = next(); break;
			case "--tag":          args.tag = next(); break;
			case "--harness":      args.harness = next(); break;
			case "--no-enter":     args.sendEnter = false; break;
			case "--no-clear":     args.clearBell = false; break;
			case "--keys-allow-tmux": args.keysAllowTmux = true; break;
			case "--confirm-advanced": args.confirmAdvanced = true; break;
			case "--question":     args.mode = "question"; args.questionId = next(); break;
			case "--answer":       args.answerLabel = next(); break;
			case "--answer-multi": args.answerMultiCsv = next(); break;
			case "--answer-text":  args.answerText = next(); break;
			case "--answers-json": args.answersJson = next(); break;
			case "--reject":       args.rejectQuestion = true; break;
			default: die(`Unknown flag: ${cur}`);
		}
	}
	return args;
}

function validate(args: Args): void {
	switch (args.mode) {
		case "option":
			if (!/^[1-9][0-9]*$/.test(args.optionN)) die("Error: --option requires a positive integer");
			if (args.payload) die("Error: --option is mutually exclusive with positional payload");
			if (args.tag === "multi-select-tabbed") {
				process.stderr.write("Error: tag 'multi-select-tabbed' requires --option-multi N1,N2,..., not --option N\n");
				process.stderr.write("       --option walks the list and toggles items along the path.\n");
				process.exit(1);
			}
			break;
		case "option-multi":
			if (!args.optionMultiCsv) die("Error: --option-multi requires a comma-separated list of integers");
			if (!/^[1-9][0-9]*(,[1-9][0-9]*)*$/.test(args.optionMultiCsv)) die("Error: --option-multi must be CSV of positive integers (e.g. 1,3,4)");
			if (args.payload) die("Error: --option-multi is mutually exclusive with positional payload");
			break;
		case "keys":
			if (!args.keysCsv) die("Error: --keys requires a comma-separated list");
			if (args.payload) die("Error: --keys is mutually exclusive with positional payload");
			break;
		case "payload":
			if (!args.payload) die("Usage: pane-respond <pane-target> <payload>|--option N|--keys k1,k2,... [flags]");
			break;
		case "question": {
			if (!args.questionId) die("Error: --question requires a request_id (que_…)");
			if (args.payload) die("Error: --question is mutually exclusive with positional payload");
			const modes = [args.answerLabel, args.answerMultiCsv, args.answerText, args.answersJson].filter(Boolean).length;
			if (!args.rejectQuestion && modes === 0) die("Error: --question requires --answer <label>, --answer-multi <l1,l2,...>, --answer-text <text>, --answers-json '[[...]]', or --reject");
			if (modes > 1) die("Error: --answer, --answer-multi, --answer-text, and --answers-json are mutually exclusive");
			if (args.answersJson) {
				try {
					const v = JSON.parse(args.answersJson);
					if (!Array.isArray(v) || !v.every((x: unknown) => Array.isArray(x))) die("Error: --answers-json must be a JSON array of per-tab arrays, e.g. '[[\"A\"],[\"B\"]]'");
				} catch { die("Error: --answers-json must be a JSON array of per-tab arrays, e.g. '[[\"A\"],[\"B\"]]'"); }
			}
			if (args.rejectQuestion && modes > 0) die("Error: --reject is mutually exclusive with answer flags");
			if (args.harness !== "opencode" && args.harness !== "pi") die("Error: --question is only supported for harness=opencode or harness=pi", 1);
			if (args.harness === "opencode" && args.answerText) die("Error: --answer-text is only supported for harness=pi questions with allowCustom=true", 1);
			break;
		}
	}
	if (!args.target.includes(".")) die("Error: target must include explicit pane index (e.g., HT:cc-463.0)");

	if (args.mode === "payload" && args.tag === "rebase-multi-choice") {
		const missing: string[] = [];
		if (!args.payload.includes("PRESERVE:")) missing.push("PRESERVE");
		if (!args.payload.includes("APPLY:")) missing.push("APPLY");
		if (!args.payload.includes("VERIFY:")) missing.push("VERIFY");
		if (missing.length > 0) {
			process.stderr.write(`Error: rebase-multi-choice payload missing required section(s): ${missing.join(" ")}\n`);
			process.stderr.write("       Each rebase response must include PRESERVE / APPLY / VERIFY (see patterns/prompt-handlers.md).\n");
			process.exit(1);
		}
	}
}

function tmuxSend(target: string, key: string): void {
	const r = spawnSync("tmux", ["send-keys", "-t", target, key], { encoding: "utf8" });
	if (r.status !== 0) {
		process.stderr.write(`Error: tmux send-keys failed for ${target} (key=${key}): ${r.stderr || "non-zero exit"}\n`);
		process.exit(5);
	}
}

function tmuxRun(args: string[], opts: { input?: string } = {}): void {
	const r = spawnSync("tmux", args, { encoding: "utf8", input: opts.input });
	if (r.status !== 0) {
		process.stderr.write(`Error: tmux ${args[0]} failed: ${r.stderr || "non-zero exit"}\n`);
		process.exit(5);
	}
}

function paneRegistry(args: string[]): string {
	const r = spawnSync(PANE_REGISTRY, args, { encoding: "utf8" });
	if (r.status !== 0) return "";
	const raw = (r.stdout ?? "").trim();
	if (args[0] !== "find-by-pane" || !raw.startsWith("{")) return raw;
	try {
		const parsed = JSON.parse(raw) as { id?: unknown };
		return typeof parsed.id === "string" ? parsed.id : "";
	} catch {
		return "";
	}
}

function extractFlag(s: string, flag: string): string {
	const m = s.match(new RegExp(`${flag}\\s+(\\S+)`));
	return m ? m[1]! : "";
}

// ---- claude option-pick adapter (tmux fallback) ---------------------------

function claudeSelectOption(pane: string, n: number): void {
	const steps = n - 1;
	for (let i = 0; i < steps; i += 1) tmuxSend(pane, "Down");
	tmuxSend(pane, "Enter");
}

function claudeSelectOptionMulti(pane: string, csv: string): void {
	const picks = Array.from(new Set(csv.split(",").map((x) => Number.parseInt(x.trim(), 10)))).sort((a, b) => a - b);
	let prev = 1;
	for (const n of picks) {
		const steps = n - prev;
		for (let i = 0; i < steps; i += 1) tmuxSend(pane, "Down");
		tmuxSend(pane, "Space");
		prev = n;
	}
	tmuxSend(pane, "Right");
	tmuxSend(pane, "Enter");
}

const KEYS_ALLOWED = /^(Up|Down|Left|Right|Enter|Tab|Space|Escape|BSpace)$/;

function sendKeysSequence(pane: string, csv: string): void {
	const keys = csv.split(",");
	for (const k of keys) {
		if (!KEYS_ALLOWED.test(k)) {
			process.stderr.write(`Error: unrecognized key '${k}' (allowed: Up Down Left Right Enter Tab Space Escape BSpace)\n`);
			process.exit(1);
		}
		tmuxSend(pane, k);
	}
}

function paneIsBusy(pane: string, harness: string): boolean {
	if (harness !== "claude") return false;
	const r = spawnSync("tmux", ["capture-pane", "-t", pane, "-p"], { encoding: "utf8" });
	if (r.status !== 0) return false;
	const tail = (r.stdout ?? "").split("\n").slice(-3).join("\n");
	return /⠋|⠙|⠸|⠴|⠦|⠧|⠇|⠏/.test(tail);
}

function verifyPromptAdvanced(pane: string): boolean {
	const deadline = Date.now() + 8000;
	while (Date.now() < deadline) {
		const r = spawnSync("tmux", ["capture-pane", "-t", pane, "-p"], { encoding: "utf8" });
		const tail = (r.stdout ?? "").split("\n").slice(-12).join("\n");
		if (!/(Enter to (select|toggle|submit)|↑.*↓ (to )?navigate|esc.*dismiss|↑↓ select)/.test(tail)) return true;
		spawnSync("sleep", ["0.5"]);
	}
	return false;
}

function isExecutable(p: string): boolean {
	try {
		const s = statSync(p);
		return s.isFile() && (s.mode & 0o111) !== 0;
	} catch { return false; }
}

function resolveOpencodeBin(): string | null {
	if (isExecutable("/usr/bin/opencode")) return "/usr/bin/opencode";
	const r = spawnSync("bash", ["-c", "type -P opencode 2>/dev/null"], { encoding: "utf8" });
	const p = (r.stdout ?? "").trim();
	if (p && isExecutable(p)) return p;
	return null;
}

function opencodeRunAttach(url: string, sid: string, message: string): number {
	const deadlineSecs = Number.parseInt(process.env.FD_ATTACH_TIMEOUT ?? "30", 10);
	const bin = resolveOpencodeBin();
	if (!bin) { process.stderr.write("Error: opencode binary not found\n"); return 5; }
	// Bash uses --max-time 5 for the pre-send snapshot and 3 for polls
	// (review-xharness finding) — mirror that.
	const userCount = (timeoutSec: number): number => {
		const r = spawnSync("curl", ["-s", "--max-time", String(timeoutSec), `${url}/session/${sid}/message`], { encoding: "utf8" });
		if (r.status !== 0 || !r.stdout) return 0;
		const jq = spawnSync("jq", ['[.[] | select(((.info.role // .role // .message.role) // "") == "user")] | length'], {
			encoding: "utf8",
			input: r.stdout,
		});
		const n = Number.parseInt((jq.stdout ?? "0").trim(), 10);
		return Number.isFinite(n) ? n : 0;
	};
	const before = userCount(5);
	const stateDir = process.env.FD_STATE_DIR ?? `${process.env.XDG_RUNTIME_DIR ?? "/tmp"}/flightdeck`;
	const log = `${stateDir}/oc-respond-${process.pid}-${Date.now()}.log`;
	// Direct setsid argv spawn — NO bash -c, NO shell interpolation of
	// the message. setsid detaches from our controlling tty; child stdin
	// is /dev/null, child stdout+stderr append to `log`. Bun.spawn would
	// be cleaner async; spawnSync + detached:true is the sync-friendly
	// equivalent for the trampoline path.
	const { openSync, closeSync } = require("node:fs") as typeof import("node:fs");
	try {
		const logFd = openSync(log, "a");
		const child = spawnSync("setsid", ["--fork", bin, "run", "--attach", url, "--session", sid, "--format", "json", message], {
			stdio: ["ignore", logFd, logFd],
		});
		closeSync(logFd);
		void child;
	} catch { /* setsid --fork detaches; spawnSync returns immediately */ }
	const deadline = Date.now() + deadlineSecs * 1000;
	let rc = 5;
	while (Date.now() < deadline) {
		if (userCount(3) > before) { rc = 0; break; }
		spawnSync("sleep", ["0.5"]);
	}
	try { spawnSync("rm", ["-f", log], { stdio: "ignore" }); } catch { /* */ }
	if (rc !== 0) process.stderr.write(`Error: user message did not land in /session/${sid}/message within ${deadlineSecs}s — server unreachable or session gone\n`);
	return rc;
}

// ---- main -----------------------------------------------------------------

const args = parseArgs();
validate(args);

let ocAdapterUsed = false;
let ccAdapterUsed = false;
let piAdapterUsed = false;
let cxAdapterUsed = false;

// Question mode — oc / pi only.
if (args.mode === "question" && args.harness === "opencode") {
	const ocIssue = paneRegistry(["find-by-pane", args.target]);
	let ocAttachArgs = ocIssue ? paneRegistry(["oc-attach-args", ocIssue]) : "";
	if (!ocAttachArgs) {
		const derived = ocIssueFromPaneTarget(args.target);
		if (derived) ocAttachArgs = ocAttachArgsFromSpawn(derived) ?? "";
	}
	if (!ocAttachArgs) die(`Error: --question requires opencode adapter (no oc-attach metadata for ${args.target})`, 5);
	const ocUrl = extractFlag(ocAttachArgs, "--url");
	if (!ocUrl) die(`Error: could not resolve opencode url for ${args.target}`, 5);
	if (args.rejectQuestion) {
		const r = spawnSync("curl", ["-sf", "-X", "POST", "-o", "/dev/null", "--max-time", "10", `${ocUrl}/question/${args.questionId}/reject`], { stdio: "inherit" });
		if (r.status !== 0) die(`Error: question reject failed (POST ${ocUrl}/question/${args.questionId}/reject)`, 5);
		process.stdout.write(`  oc-question-rejected: ${args.questionId}\n`);
	} else {
		let payload = "";
		if (args.answersJson) payload = JSON.stringify({ answers: JSON.parse(args.answersJson) });
		else if (args.answerLabel) payload = JSON.stringify({ answers: [[args.answerLabel]] });
		else payload = JSON.stringify({ answers: [args.answerMultiCsv.split(",")] });
		const r = spawnSync("curl", ["-sf", "-X", "POST", "-H", "Content-Type: application/json", "-d", payload, "--max-time", "10", `${ocUrl}/question/${args.questionId}/reply`], { encoding: "utf8" });
		const resp = (r.stdout ?? "").trim();
		if (r.status !== 0 || resp !== "true") die(`Error: question reply failed (POST ${ocUrl}/question/${args.questionId}/reply): ${resp || r.stderr}`, 5);
		process.stdout.write(`  oc-question-answered: ${args.questionId} payload=${payload}\n`);
	}
	ocAdapterUsed = true;
}

if (args.mode === "question" && args.harness === "pi") {
	const piIssue = paneRegistry(["find-by-pane", args.target]);
	let piArgs = piIssue ? paneRegistry(["pi-bridge-args", piIssue]) : "";
	if (!piArgs) {
		const derived = ocIssueFromPaneTarget(args.target);
		if (derived) {
			const spawn = piSpawnFile(derived);
			if (existsSync(spawn)) {
				try {
					const rec = JSON.parse(readFileSync(spawn, "utf8")) as Record<string, unknown>;
					const pid = String(rec.pid ?? "");
					const sock = String(rec.socket ?? "");
					if (pid && sock && piBridgeIsFresh(Number(pid), sock)) piArgs = `--pid ${pid} --socket ${sock}`;
				} catch { /* */ }
			}
		}
	}
	if (!piArgs) die(`Error: --question requires pi bridge adapter (no pi-bridge metadata for ${args.target})`, 5);
	const piPid = extractFlag(piArgs, "--pid");
	const piSocket = extractFlag(piArgs, "--socket");
	if (!piPid && !piSocket) die(`Error: could not resolve pi pid/socket for ${args.target}`, 5);
	const target = piSocket ? ["--socket", piSocket] : ["--pid", piPid];
	const bin = piResolveBridgeBin();
	if (!bin) die("Error: pi-bridge binary not found", 5);
	if (args.rejectQuestion) {
		const r = spawnSync(bin, ["reject", ...target, "--request-id", args.questionId], { encoding: "utf8" });
		const resp = (r.stdout ?? "").trim();
		if (r.status !== 0) die(`Error: pi question reject failed: ${resp || r.stderr}`, 5);
		try {
			const ok = JSON.parse(resp || "{}").success === true;
			if (!ok) die(`Error: pi question reject returned non-success: ${resp}`, 5);
		} catch { die(`Error: pi question reject returned non-success: ${resp}`, 5); }
		process.stdout.write(`  pi-question-rejected: ${args.questionId}\n`);
	} else {
		let payload = "";
		if (args.answersJson) payload = args.answersJson;
		else if (args.answerLabel) payload = JSON.stringify([[args.answerLabel]]);
		else if (args.answerText) payload = JSON.stringify([[args.answerText]]);
		else payload = JSON.stringify([args.answerMultiCsv.split(",")]);
		const r = spawnSync(bin, ["answer", ...target, "--request-id", args.questionId, "--answers", payload], { encoding: "utf8" });
		const resp = (r.stdout ?? "").trim();
		if (r.status !== 0) die(`Error: pi question answer failed: ${resp || r.stderr}`, 5);
		try {
			const ok = JSON.parse(resp || "{}").success === true;
			if (!ok) die(`Error: pi question answer returned non-success: ${resp}`, 5);
		} catch { die(`Error: pi question answer returned non-success: ${resp}`, 5); }
		process.stdout.write(`  pi-question-answered: ${args.questionId} payload=${payload}\n`);
	}
	piAdapterUsed = true;
}

// Adapter mode for free-text / option / option-multi (not question).
if (args.harness === "opencode" && !ocAdapterUsed) {
	const issue = paneRegistry(["find-by-pane", args.target]);
	let attachArgs = issue ? paneRegistry(["oc-attach-args", issue]) : "";
	if (!attachArgs) {
		const derived = ocIssueFromPaneTarget(args.target);
		if (derived) attachArgs = ocAttachArgsFromSpawn(derived) ?? "";
	}
	if (attachArgs) {
		if (args.mode === "keys" && !args.keysAllowTmux) {
			process.stderr.write("Error: --keys not supported for opencode adapter.\n       Pass --keys-allow-tmux to send via tmux send-keys (true modal cases only).\n");
			process.exit(1);
		}
		if (args.mode !== "keys") {
			const url = extractFlag(attachArgs, "--url");
			const sid = extractFlag(attachArgs, "--session");
			const msg = args.mode === "payload" ? args.payload
				: args.mode === "option" ? args.optionN
				: args.optionMultiCsv.replace(/,/g, ", ");
			if (opencodeRunAttach(url, sid, msg) !== 0) process.exit(5);
			ocAdapterUsed = true;
		}
	} else {
		process.stderr.write(`Note: oc-attach-unavailable for ${args.target} (no registry metadata); using tmux fallback\n`);
	}
}

if (args.harness === "claude" && !ocAdapterUsed) {
	const issue = paneRegistry(["find-by-pane", args.target]);
	let ccArgs = issue ? paneRegistry(["cc-channel-args", issue]) : "";
	if (!ccArgs) {
		const derived = ocIssueFromPaneTarget(args.target);
		if (derived) {
			const spawn = ccSpawnFile(derived);
			if (existsSync(spawn)) {
				try {
					const rec = JSON.parse(readFileSync(spawn, "utf8")) as Record<string, unknown>;
					const url = String(rec.url ?? "");
					const tr = String(rec.transcript ?? "");
					if (url && tr) ccArgs = `--url ${url} --transcript ${tr}`;
				} catch { /* */ }
			}
		}
	}
	if (ccArgs) {
		if (args.mode === "keys" && !args.keysAllowTmux) {
			process.stderr.write("Error: --keys not supported for claude channels adapter.\n       Pass --keys-allow-tmux to send via tmux send-keys (true modal cases only).\n");
			process.exit(1);
		}
		if (args.mode !== "keys") {
			const url = extractFlag(ccArgs, "--url");
			const msg = args.mode === "payload" ? args.payload
				: args.mode === "option" ? args.optionN
				: args.optionMultiCsv.replace(/,/g, ", ");
			const r = spawnSync("curl", ["-s", "-m", "10", "-X", "POST", "-d", msg, `${url}/`], { encoding: "utf8" });
			if (r.status !== 0) die(`Error: claude channel POST failed (rc=${r.status}): ${r.stdout || r.stderr}`, 5);
			if (!/^ok /m.test(r.stdout ?? "")) die(`Error: claude channel POST returned unexpected body: ${r.stdout}`, 5);
			ccAdapterUsed = true;
		}
	} else {
		process.stderr.write(`Note: cc-channel-unavailable for ${args.target} (no registry metadata); using tmux fallback\n`);
	}
}

if (args.harness === "pi" && !ocAdapterUsed && !ccAdapterUsed && !piAdapterUsed) {
	const issue = paneRegistry(["find-by-pane", args.target]);
	let piArgs = issue ? paneRegistry(["pi-bridge-args", issue]) : "";
	if (!piArgs) {
		const derived = ocIssueFromPaneTarget(args.target);
		if (derived) {
			const spawn = piSpawnFile(derived);
			if (existsSync(spawn)) {
				try {
					const rec = JSON.parse(readFileSync(spawn, "utf8")) as Record<string, unknown>;
					const pid = String(rec.pid ?? "");
					const sock = String(rec.socket ?? "");
					if (pid && sock && piBridgeIsFresh(Number(pid), sock)) piArgs = `--pid ${pid} --socket ${sock}`;
				} catch { /* */ }
			}
		}
	}
	if (piArgs) {
		if (args.mode === "keys" && !args.keysAllowTmux) {
			process.stderr.write("Error: --keys not supported for pi bridge adapter.\n       Pass --keys-allow-tmux to send via tmux send-keys (true modal cases only).\n");
			process.exit(1);
		}
		if (args.mode !== "keys") {
			const pid = extractFlag(piArgs, "--pid");
			const sock = extractFlag(piArgs, "--socket");
			const target = sock ? ["--socket", sock] : ["--pid", pid];
			const msg = args.mode === "payload" ? args.payload
				: args.mode === "option" ? args.optionN
				: args.optionMultiCsv.replace(/,/g, ", ");
			const bin = piResolveBridgeBin();
			if (!bin) die("Error: pi-bridge binary not found", 5);
			const r = spawnSync(bin, ["send", ...target, "--auto", msg], { encoding: "utf8" });
			if (r.status !== 0) die(`Error: pi-bridge send failed: ${r.stdout || r.stderr}`, 5);
			piAdapterUsed = true;
		}
	} else {
		process.stderr.write(`Note: pi-bridge-unavailable for ${args.target} (no registry/spawn metadata or stale bridge); using tmux fallback\n`);
	}
}

if (args.harness === "codex" && !ocAdapterUsed && !ccAdapterUsed && !piAdapterUsed) {
	const issue = paneRegistry(["find-by-pane", args.target]);
	let cxArgs = issue ? paneRegistry(["cx-bridge-args", issue]) : "";
	if (!cxArgs) {
		const derived = ocIssueFromPaneTarget(args.target);
		if (derived) {
			const spawn = cxSpawnFile(derived);
			if (existsSync(spawn)) {
				try {
					const rec = JSON.parse(readFileSync(spawn, "utf8")) as Record<string, unknown>;
					const url = String(rec.url ?? "");
					const thread = String(rec.thread_id ?? "");
					if (url && thread) cxArgs = `--url ${url} --thread ${thread}`;
				} catch { /* */ }
			}
		}
	}
	if (cxArgs) {
		if (args.mode === "keys" && !args.keysAllowTmux) {
			process.stderr.write("Error: --keys not supported for codex bridge adapter.\n       Pass --keys-allow-tmux to send via tmux send-keys.\n");
			process.exit(1);
		}
		if (args.mode !== "keys") {
			const url = extractFlag(cxArgs, "--url");
			const thread = extractFlag(cxArgs, "--thread");
			const msg = args.mode === "payload" ? args.payload
				: args.mode === "option" ? args.optionN
				: args.optionMultiCsv.replace(/,/g, ", ");
			const r = cxBridgeRun(["send", "--url", url, "--thread", thread, "--", msg]);
			if (r.status !== 0) die(`Error: codex-bridge send failed: ${r.stdout || r.stderr}`, 5);
			cxAdapterUsed = true;
		}
	} else {
		process.stderr.write(`Note: cx-bridge-unavailable for ${args.target} (no registry/spawn metadata); using tmux fallback\n`);
	}
}

if (!ocAdapterUsed && !ccAdapterUsed && !piAdapterUsed && !cxAdapterUsed) {
	if (paneIsBusy(args.target, args.harness)) {
		process.stderr.write(`Error: pane ${args.target} shows active spinner; refusing to send. Wait and retry.\n`);
		process.exit(3);
	}
	switch (args.mode) {
		case "option":
			if (args.harness === "claude") claudeSelectOption(args.target, Number.parseInt(args.optionN, 10));
			else {
				process.stderr.write(`Error: --option not supported for harness '${args.harness}' in tmux fallback\n       Use payload mode (free-text digit) instead, or add an adapter.\n`);
				process.exit(1);
			}
			break;
		case "option-multi":
			if (args.harness === "claude") claudeSelectOptionMulti(args.target, args.optionMultiCsv);
			else {
				process.stderr.write(`Error: --option-multi not yet supported for harness '${args.harness}'\n       Add an adapter in pane-respond before using.\n`);
				process.exit(1);
			}
			break;
		case "keys":
			sendKeysSequence(args.target, args.keysCsv);
			break;
		case "payload": {
			const bufName = `flightdeck-respond-${process.pid}`;
			tmuxRun(["load-buffer", "-b", bufName, "-"], { input: args.payload });
			tmuxRun(["paste-buffer", "-b", bufName, "-t", args.target, "-p"]);
			// delete-buffer is best-effort; tmux unlinks the buffer for us.
			spawnSync("tmux", ["delete-buffer", "-b", bufName]);
			if (args.sendEnter) tmuxSend(args.target, "Enter");
			break;
		}
		case "question":
			// Already handled above; nothing else to do in fallback.
			break;
	}
	if (args.confirmAdvanced) {
		if (!verifyPromptAdvanced(args.target)) die(`Error: prompt sentinel still present 8s after send to ${args.target}; advance not confirmed.`, 4);
	}
}

if (args.clearBell) {
	const windowTarget = args.target.slice(0, args.target.lastIndexOf("."));
	spawnSync(PANE_CLEAR_BELL, [windowTarget], { stdio: "inherit" });
}
