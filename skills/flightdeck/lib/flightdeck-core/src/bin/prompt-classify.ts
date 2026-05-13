#!/usr/bin/env bun
// CLI parity port of skills/flightdeck/scripts/prompt-classify.
// Reads buffer from --buffer-file or stdin; prints tag on stdout.
// --dry-run additionally prints the matched-line annotation when present.

import { readFileSync } from "node:fs";
import { classifyBuffer } from "../classifier/classify.ts";

function usage(): never {
	process.stderr.write("Usage: prompt-classify [--buffer-file <path>] [--dry-run] [--no-footer-gate] [--entry-kind <kind>]\n");
	process.exit(2);
}

let bufferFile = "";
let dryRun = false;
let noFooterGate = false;
let entryKind = "";

const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 1) {
	const a = args[i]!;
	if (a === "--buffer-file") { bufferFile = args[++i] ?? ""; continue; }
	if (a.startsWith("--buffer-file=")) { bufferFile = a.slice("--buffer-file=".length); continue; }
	if (a === "--dry-run") { dryRun = true; continue; }
	if (a === "--no-footer-gate") { noFooterGate = true; continue; }
	if (a === "--entry-kind" || a === "--kind") { entryKind = args[++i] ?? ""; continue; }
	if (a.startsWith("--entry-kind=") || a.startsWith("--kind=")) { entryKind = a.slice(a.indexOf("=") + 1); continue; }
	process.stderr.write(`Unknown flag: ${a}\n`);
	process.exit(2);
}

let buf: string;
if (bufferFile) {
	buf = readFileSync(bufferFile, "utf8");
} else {
	const chunks: Buffer[] = [];
	for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
	buf = Buffer.concat(chunks).toString("utf8");
}

const unguarded = classifyBuffer(buf, { noFooterGate });
const result = classifyBuffer(buf, { entryKind, noFooterGate });
if (result.tag === "domain-mismatch" && unguarded.tag !== result.tag) {
	process.stderr.write(`Warning: issue-only prompt tag ${unguarded.tag} appeared on ${entryKind || "unknown"} entry; routing as domain-mismatch.\n`);
}
if (dryRun && result.matched) {
	process.stdout.write(`${result.tag}\t${result.matched}\n`);
} else {
	process.stdout.write(`${result.tag}\n`);
}
usage; // silence unused
