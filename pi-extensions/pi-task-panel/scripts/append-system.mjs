#!/usr/bin/env node
// Vendored helper. Identical copy ships in every Pi extension package that
// declares `pi.appendSystem`. Keeping it self-contained avoids a runtime
// dependency between packages — npm runs it during `postinstall` and
// `preuninstall`, and kendex's Rust CLI implements the same upsert/remove
// logic in pi_extension.rs.
//
// Usage: node scripts/append-system.mjs <install|remove>
//
// Resolves the scope-appropriate APPEND_SYSTEM.md by:
//
// 1. Walking up from the package dir until it finds a kendex `packages/`
//    segment or Pi's npm-managed `npm/node_modules/` segment; the parent of
//    that install root is the Pi scope root (`~/.pi/agent` for user/global,
//    `<project>/.pi` for project). This handles kendex-driven installs under
//    `<scope>/packages/<name>` and Pi 0.75+ npm installs under
//    `<scope>/npm/node_modules/<name>`.
//
// 2. If neither managed segment is found (legacy npm global-prefix installs
//    or manual `npm install`), we fall back to the conventional Pi user dir
//    from `PI_CODING_AGENT_DIR` (or `~/.pi/agent`). We only act when that dir
//    already exists — npm installing one of these packages on a machine
//    without Pi must not create stray files.

import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

// npm invokes this file directly; notices retain their key and value even
// when their explanation changes. JSON quoting keeps input values on one line.
function notice(key, value, explanation) {
	console.error(`append-system: ${key}=${JSON.stringify(value)}`);
	console.error(explanation);
}

const action = process.argv[2];
if (action !== "install" && action !== "remove") {
	notice("action", action ?? null, 'Expected "install" or "remove".');
	process.exit(1);
}

const pkgDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");

let pkg;
try {
	pkg = JSON.parse(readFileSync(join(pkgDir, "package.json"), "utf8"));
} catch (err) {
	notice("package-read", pkgDir, `Unable to read package.json: ${err?.message ?? err}`);
	process.exit(0);
}

const name = typeof pkg?.name === "string" ? pkg.name : undefined;
const rel = pkg?.pi?.appendSystem;
if (!name || typeof rel !== "string") {
	notice("package-fields", pkgDir, "The package needs name and pi.appendSystem fields.");
	process.exit(0);
}

const scopeRoot = findScopeRoot(pkgDir);
if (!scopeRoot) {
	notice("scope", pkgDir, `Unable to resolve the Pi scope for ${name}.`);
	process.exit(0);
}

const target = join(scopeRoot, "APPEND_SYSTEM.md");
const begin = `<!-- kendex:append-system ${name} begin -->`;
const end = `<!-- kendex:append-system ${name} end -->`;

try {
	if (action === "install") {
		const sourcePath = resolve(pkgDir, rel);
		if (!existsSync(sourcePath)) {
			notice("source-missing", sourcePath, `The appendSystem source for ${name} is missing.`);
			process.exit(0);
		}
		const content = readFileSync(sourcePath, "utf8").trim();
		if (!content) {
			notice("source-empty", sourcePath, `The appendSystem source for ${name} is empty.`);
			process.exit(0);
		}
		upsertBlock(target, begin, end, content);
	} else {
		removeBlock(target, begin, end);
	}
} catch (err) {
	// Never fail the npm install/uninstall over an APPEND_SYSTEM.md write.
	notice("operation", `${action}:${name}:${err?.code ?? "unknown"}`, `Unable to update APPEND_SYSTEM.md: ${err?.message ?? err}`);
	process.exit(0);
}

function findScopeRoot(start) {
	let dir = start;
	while (true) {
		const parent = dirname(dir);
		if (parent === dir) break;
		if (basename(parent) === "packages") return dirname(parent);
		if (basename(parent) === "node_modules" && basename(dirname(parent)) === "npm") {
			const scopeRoot = dirname(dirname(parent));
			if (isPiScopeRoot(scopeRoot)) return scopeRoot;
		}
		dir = parent;
	}
	// Fallback: the conventional Pi user dir, but only when it already exists.
	// This catches legacy global-prefix installs without mutating arbitrary user
	// state on machines without Pi installed.
	const configured = process.env.PI_CODING_AGENT_DIR;
	const piDir = configured ? resolve(configured.replace(/^~(?=\/|$)/, homedir())) : join(homedir(), ".pi", "agent");
	return existsSync(piDir) ? piDir : undefined;
}

function isPiScopeRoot(scopeRoot) {
	if (existsSync(join(scopeRoot, "settings.json"))) return true;
	if (basename(scopeRoot) === ".pi") return true;
	const configured = process.env.PI_CODING_AGENT_DIR;
	const piDir = configured ? resolve(configured.replace(/^~(?=\/|$)/, homedir())) : join(homedir(), ".pi", "agent");
	return resolve(scopeRoot) === resolve(piDir);
}

function escapeRegExp(s) {
	return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function strippedExisting(target, begin, end) {
	if (!existsSync(target)) return "";
	// Splice the begin..end span out without touching surrounding newlines,
	// then collapse 3+ consecutive newlines so a removed sandwiched block
	// doesn't leave a gap. trim leading/trailing newlines last.
	const re = new RegExp(`${escapeRegExp(begin)}[\\s\\S]*?${escapeRegExp(end)}`, "g");
	return readFileSync(target, "utf8")
		.replace(re, "")
		.replace(/\n{3,}/g, "\n\n")
		.replace(/^\n+/, "")
		.replace(/\n+$/, "");
}

function upsertBlock(target, begin, end, content) {
	mkdirSync(dirname(target), { recursive: true });
	const stripped = strippedExisting(target, begin, end);
	const block = `${begin}\n${content}\n${end}`;
	const next = stripped ? `${stripped}\n\n${block}\n` : `${block}\n`;
	writeFileSync(target, next);
}

function removeBlock(target, begin, end) {
	if (!existsSync(target)) return;
	const stripped = strippedExisting(target, begin, end);
	if (stripped) {
		writeFileSync(target, `${stripped}\n`);
	} else {
		try {
			unlinkSync(target);
		} catch (err) {
			if (err?.code !== "ENOENT") throw err;
		}
	}
}
