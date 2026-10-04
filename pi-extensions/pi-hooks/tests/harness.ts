import { afterAll, beforeAll } from "bun:test";
import { chmodSync, cpSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import piHooks from "../extensions/hooks.ts";
import { clearPackageConfigCache } from "../extensions/package-config.ts";

/* Fixtures shared by the pi-hooks suites. */

export const CONFIG_ID = "@vanillagreen/pi-hooks";

/** The session every fixture ctx carries: Pi hands each listener a session
 * manager, and this one has an id and no session file. */
export const SESSION_ID = "pi-hooks-session";
export const sessionManager = { getSessionId: () => SESSION_ID, getSessionFile: (): string | undefined => undefined };

/** A disposable carrier whose named behavior is removed without deleting its
 * matched code. The same real-session assertions run against this copy. */
export function mutatedCarrier(root: string, name: string, file: string, before: string, after: string): string {
	const copy = join(root, `${name}-extensions`);
	cpSync(join(import.meta.dir, "..", "extensions"), copy, { recursive: true });
	const path = join(copy, file);
	if (lstatSync(path).isSymbolicLink()) throw new Error(`${file} mutation target is a symlink`);
	const source = readFileSync(path, "utf8");
	if (source.split(before).length !== 2) throw new Error(`${file} holds the mutation target other than once`);
	const mutant = source.replace(before, after);
	if (mutant === source) throw new Error(`${file} mutation changed nothing`);
	writeFileSync(path, mutant);
	return join(copy, "hooks.ts");
}

export type ToolCallHandler = (event: { toolName: string; input: Record<string, unknown> }, ctx: Record<string, unknown>) => Promise<unknown>;

export function runGit(args: string[], cwd: string): void {
	const result = spawnSync("git", args, { cwd, encoding: "utf8", env: process.env });
	if (result.status !== 0) {
		throw new Error(`git ${args.join(" ")} failed: ${result.stderr || result.stdout}`);
	}
}

/** `overrides` are merged over the fixture defaults, for a case whose subject
 * is one setting: a budget a hook has to overrun, a guard toggle turned off. */
export function writePiConfig(project: string, overrides: Record<string, unknown> = {}): void {
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeFileSync(join(project, ".pi", "settings.json"), JSON.stringify({
		kendex: {
			extensionManager: {
				config: {
					[CONFIG_ID]: {
						enabled: true,
						preCommitCheck: true,
						taskCompletedCheck: false,
						clippyTimeoutMs: 3000,
						...overrides,
					},
				},
			},
		},
	}, null, 2));
	// What pi-extension-manager's settings-changed event does after a write.
	clearPackageConfigCache();
}

/* Git reads no config of the developer's here: a global core.hooksPath would
 * disarm every fixture, and a global init.templateDir can leave git init
 * without the hooks directory the fixtures write into. Each suite calls this
 * once, because bun's beforeAll is per file.
 *
 * GIT_DIR, GIT_COMMON_DIR, GIT_WORK_TREE and GIT_INDEX_FILE are cleared
 * together, the rule AGENTS.md states: a suite run from a git hook context
 * inherits them, and every `git init`, `git add` and `git commit` a fixture
 * makes would then land in the real repository's index rather than the
 * temporary one it just created. Clearing three of the four leaves the same
 * hole. */
const CLEARED = ["GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"] as const;

export function useIsolatedGitEnv(): void {
	const isolatedEnv: Record<string, string> = { GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" };
	const savedEnv: Record<string, string | undefined> = {};
	let emptyAgentDir: string | undefined;
	beforeAll(() => {
		for (const [name, value] of Object.entries(isolatedEnv)) {
			savedEnv[name] = process.env[name];
			process.env[name] = value;
		}
		for (const name of CLEARED) {
			savedEnv[name] = process.env[name];
			delete process.env[name];
		}
		// Unset, piUserDir() is ~/.pi/agent, so the developer's own global
		// registry and settings answer as a second scope in every case that
		// does not name one. An empty root is the one nobody has installed to.
		savedEnv.PI_CODING_AGENT_DIR = process.env.PI_CODING_AGENT_DIR;
		emptyAgentDir = mkdtempSync(join(tmpdir(), "pi-hooks-empty-agent-"));
		process.env.PI_CODING_AGENT_DIR = emptyAgentDir;
		clearPackageConfigCache();
		// The carrier names the calling agent from this, and a suite run from
		// inside a Pi subagent inherits it.
		savedEnv.PI_SUBAGENT_CHILD_AGENT = process.env.PI_SUBAGENT_CHILD_AGENT;
		delete process.env.PI_SUBAGENT_CHILD_AGENT;
	});
	afterAll(() => {
		for (const [name, value] of Object.entries(savedEnv)) {
			if (value === undefined) delete process.env[name];
			else process.env[name] = value;
		}
		clearPackageConfigCache();
		if (emptyAgentDir !== undefined) rmSync(emptyAgentDir, { recursive: true, force: true });
	});
}

export function initRustRepo(prefix: string): string {
	const dir = mkdtempSync(join(tmpdir(), prefix));
	runGit(["init", "-q"], dir);
	mkdirSync(join(dir, ".git", "hooks"), { recursive: true });
	writePiConfig(dir);
	mkdirSync(join(dir, "src"), { recursive: true });
	writeFileSync(join(dir, "src", "lib.rs"), "pub fn answer() -> i32 { 42 }\n");
	runGit(["add", "src/lib.rs"], dir);
	return dir;
}

export type ListenerHandler = (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<unknown> | unknown;
export type SentMessage = { customType: string; content: string; display: boolean };
/** Both arguments of every `pi.sendMessage` call: the options decide delivery, so they are asserted. */
export type SentCall = { message: SentMessage; options: Record<string, unknown> | undefined };

/** The carrier installed against a stub Pi: every listener it registered is
 * callable by name, and every message it sends is recorded in order. One stub,
 * so a suite cannot model a Pi the other suites do not. A listener whose
 * result Pi reads, `agent_before_settle` among them, is asserted on what its
 * handler returns. */
export interface Carrier {
	sent: SentCall[];
	handler(event: string): ListenerHandler;
}

/** `onSend` runs after the call is recorded, for a case whose subject is a
 * channel that fails: Pi's session-bound `pi` throws once the session it was
 * captured from has been replaced. `extension` is the carrier's entry, a
 * `mutatedCarrier` copy's for a must-fail control. */
export function installCarrier(onSend?: (message: SentMessage) => void, extension: (pi: never) => void = piHooks): Carrier {
	const handlers = new Map<string, ListenerHandler>();
	const sent: SentCall[] = [];
	const pi = {
		on(event: string, cb: ListenerHandler) {
			handlers.set(event, cb);
		},
		sendMessage(message: SentMessage, options?: Record<string, unknown>) {
			sent.push({ message, options });
			onSend?.(message);
		},
	};
	extension(pi as never);
	return {
		sent,
		handler(event: string): ListenerHandler {
			const handler = handlers.get(event);
			if (handler === undefined) throw new Error(`the carrier registered no ${event} handler`);
			return handler;
		},
	};
}

export function installToolCallHandler(): ToolCallHandler {
	return installCarrier().handler("tool_call") as ToolCallHandler;
}

/** The kendex render of a hook, at the project path docs/adapters/pi.md gives
 * it. The extension spawns what the registry beside it names and nothing else. */
export function renderedHookPath(project: string, name: string): string {
	return join(project, ".pi", "kendex", "hooks", `${name}.sh`);
}

/**
 * Register one hook in the rendered registry under a scope root, the way
 * `crates/core/src/engine/targets.rs::pi_hook` and the `UpsertHook` edit write
 * it: keyed by Pi's listener name, matcher and all, with the command spelling
 * that scope takes. Appended, so a fixture's registration order is the order
 * the carrier runs them in.
 */
export function registerRendered(root: string, listener: string, matcher: string | undefined, command: string, timeout?: number): void {
	const path = join(root, "kendex", "hooks.json");
	mkdirSync(join(path, ".."), { recursive: true });
	let registry: { hooks: Record<string, { matcher?: string; hooks: Record<string, unknown>[] }[]> };
	try {
		registry = JSON.parse(readFileSync(path, "utf8"));
	} catch {
		registry = { hooks: {} };
	}
	const groups = (registry.hooks[listener] ??= []);
	let group = groups.find((candidate) => candidate.matcher === matcher);
	if (group === undefined) {
		group = { ...(matcher === undefined ? {} : { matcher }), hooks: [] };
		groups.push(group);
	}
	group.hooks.push({ type: "command", command, ...(timeout === undefined ? {} : { timeout }) });
	writeFileSync(path, `${JSON.stringify(registry, null, 2)}\n`);
}

/** Put a stub hook where kendex renders one, registered as kendex registers it.
 * It appends the payload it read to `log`, writes `stderr`, and exits
 * `exitCode` — so the log proves the spawn happened and carries what the
 * extension sent. */
export function renderStub(project: string, name: string, opts: StubOptions, env: Record<string, string> = {}): void {
	writeStub(renderedHookPath(project, name), opts);
	registerProjectHook(project, name, env);
}

/** `crates/core/src`, from this package. */
export function crateSrc(): string {
	return join(import.meta.dir, "..", "..", "..", "crates", "core", "src");
}

/** The body of a Rust item, by the line that opens it. */
function rustBody(file: string, opens: string): string {
	const text = readFileSync(join(crateSrc(), file), "utf8");
	const at = text.indexOf(opens);
	if (at < 0) throw new Error(`${opens} not found in crates/core/src/${file}`);
	const end = text.indexOf("\n}", at);
	if (end < 0) throw new Error(`${opens} in crates/core/src/${file} does not close`);
	return text.slice(at + opens.length, end);
}

/** The templates of the `format!` calls in `body`, in source order, each as
 * the shell it stands for. */
function rustFormats(body: string, what: string): string[] {
	const templates: string[] = [];
	for (let call = body.indexOf("format!("); call >= 0; call = body.indexOf("format!(", call + 1)) {
		const literal = /"((?:[^"\\]|\\[\s\S])*)"/.exec(body.slice(call));
		if (literal === null) throw new Error(`no format template in ${what}`);
		templates.push(rustUnescape(literal[1]!, what)
			.replaceAll("{{", "\u0001")
			.replaceAll("}}", "\u0002"));
	}
	if (templates.length === 0) throw new Error(`no format! call in ${what}`);
	return templates;
}

/** What a Rust string literal's escapes stand for, decoded in one pass so an
 * escaped backslash is never read as the start of another escape. A trailing
 * backslash continues the literal onto the next line, swallowing that line's
 * indentation with it. Any escape not decoded here throws, so the rendering
 * cannot drift from the Rust unseen. */
function rustUnescape(literal: string, what: string): string {
	const escapes: Record<string, string> = { "\\": "\\", '"': '"', "'": "'", n: "\n", t: "\t", r: "\r", "0": "\0" };
	return literal.replace(/\\(\n\s*|[\s\S])/g, (escape, next: string) => {
		if (next.startsWith("\n")) return "";
		if (!Object.hasOwn(escapes, next)) throw new Error(`${what}'s template holds the escape ${escape}, which this rendering does not decode`);
		return escapes[next]!;
	});
}

/** The template of the one `format!` call in `body`. */
function rustFormat(body: string, what: string): string {
	const templates = rustFormats(body, what);
	if (templates.length !== 1) throw new Error(`${what} holds ${templates.length} format! calls, not one`);
	return templates[0]!;
}

/**
 * `template` with each `{}` taking the next of `positional` and each
 * `{name}` taking `named[name]`. A placeholder with no value, a positional
 * value left over, or any other placeholder spelling throws, so a template
 * taking another argument on the Rust side cannot pass unread.
 */
function fill(template: string, what: string, positional: string[], named: Record<string, string> = {}): string {
	let next = 0;
	const filled = template.replace(/\{([^{}]*)\}/g, (slot, key: string) => {
		if (key === "") {
			if (next >= positional.length) throw new Error(`${what}'s template takes more than ${positional.length} positional arguments`);
			return positional[next++]!;
		}
		if (!Object.hasOwn(named, key)) throw new Error(`${what}'s template holds ${slot}, which this rendering does not fill`);
		return named[key]!;
	});
	if (next !== positional.length) throw new Error(`${what}'s template takes ${next} positional arguments, not ${positional.length}`);
	return filled;
}

function braces(text: string): string {
	return text.replaceAll("\u0001", "{").replaceAll("\u0002", "}");
}

/** A value as `crate::names::quoted` spells it for the shell. */
function quoted(value: string): string {
	return `'${value.replaceAll("'", "'\\''")}'`;
}

/**
 * The words `engine::targets::assignments` writes for `env`, rendered from
 * that function's own template in key order — empty for a hook whose
 * declaration sets nothing. Both command shapes take their assignments from
 * here, because both take them from that one function in the Rust.
 */
function assignmentsOf(env: Record<string, string>): string {
	const entry = rustFormat(rustBody("engine/targets.rs", "fn assignments(vars: Option<&BTreeMap<String, String>>) -> String {"), "assignments");
	return Object.entries(env)
		.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
		.map(([key, value]) => entry.replace("{key}", key).replace("{}", quoted(value)))
		.join("");
}

/**
 * The words `engine::targets::launch` writes to start a script under `env`,
 * rendered from that function's own template, or `bare`, the words the caller
 * spells for a hook whose declaration sets nothing.
 */
function launchOf(env: Record<string, string>, bare: string): string {
	const set = assignmentsOf(env);
	if (set === "") return bare;
	const launch = rustFormat(rustBody("engine/targets.rs", "fn launch(vars: Option<&BTreeMap<String, String>>) -> Option<String> {"), "launch");
	return launch.replace("{set}", set);
}

/**
 * The command `engine::targets::project_command` writes for `rel` and a hook
 * whose declaration sets `env`, rendered from the Rust rather than spelled
 * again here: the two halves `project_parts` builds, joined by
 * `project_command`'s own template. The walk's template takes the quoted
 * path; the run's takes the words that start the script, the bare interpreter
 * its fallback names for a hook that declares no environment. A rename, a
 * respelling or a template taking another argument on the Rust side throws,
 * which is the whole point: a carrier that reads a command kendex no longer
 * writes is every project hook silently off.
 */
export function projectCommand(rel: string, env: Record<string, string> = {}): string {
	const parts = rustBody("engine/targets.rs", "fn project_parts(rel: &str, vars: Option<&BTreeMap<String, String>>) -> (String, String) {");
	const templates = rustFormats(parts, "project_parts");
	if (templates.length !== 2) throw new Error(`project_parts holds ${templates.length} format! calls, not the walk and the run`);
	const [walk, run] = templates as [string, string];
	const bare = /unwrap_or_else\(\|\| "([^"]*)"/.exec(parts);
	if (bare === null) throw new Error("project_parts names no interpreter for a hook that declares no environment");
	return joinedCommand("project_command", "fn project_command(rel: &str, vars: Option<&BTreeMap<String, String>>) -> String {", {
		walk: fill(walk, "project_parts' walk", [quoted(rel)]),
		run: fill(run, "project_parts' run", [launchOf(env, bare[1]!)]),
	});
}

/**
 * The command `engine::targets::direct_command` writes for a global hook at
 * `path` whose declaration sets `env`, rendered from the Rust rather than
 * spelled again here: the halves one arm of `direct_parts` builds, joined by
 * `direct_command`'s own template. The no-environment arm binds nothing and
 * runs the path under a bare interpreter; the binding arm, for any other
 * `env`, takes `launch`'s words with each entry assigned in key order. A value
 * is quoted as `names::quoted` quotes it.
 */
export function globalCommand(path: string, env: Record<string, string> = {}): string {
	const parts = rustBody("engine/targets.rs", "fn direct_parts(path: &str, vars: Option<&BTreeMap<String, String>>) -> (String, String) {");
	const set = assignmentsOf(env);
	const [bind, run] = directArm(parts, set === "" ? "None =>" : "Some(launch) =>");
	const named = { path, launch: launchOf(env, "") };
	return joinedCommand("direct_command", "fn direct_command(path: &str, vars: Option<&BTreeMap<String, String>>) -> String {", {
		bind: bind === "" ? "" : fill(bind, "direct_parts' binding", [], named),
		run: fill(run, "direct_parts' run", [], named),
	});
}

/**
 * The binding and run templates of the `direct_parts` arm `opens` starts, an
 * empty binding where the arm's tuple opens with `String::new()`.
 */
function directArm(body: string, opens: string): [string, string] {
	const arms = ["None =>", "Some(launch) =>"];
	const at = body.indexOf(opens);
	if (at < 0) throw new Error(`direct_parts has no ${opens} arm`);
	const ends = arms.map((arm) => body.indexOf(arm, at + opens.length)).filter((end) => end >= 0);
	const arm = body.slice(at + opens.length, ends.length === 0 ? undefined : Math.min(...ends));
	const templates = rustFormats(arm, `direct_parts' ${opens} arm`);
	const unbound = /^\s*\(String::new\(\),/.test(arm);
	if (templates.length !== (unbound ? 1 : 2)) throw new Error(`direct_parts' ${opens} arm holds ${templates.length} format! calls, not its binding and its run`);
	return unbound ? ["", templates[0]!] : (templates as [string, string]);
}

/** The command `name`, whose body `opens`, joins from `halves` through its one
 * `format!` template. */
function joinedCommand(name: string, opens: string, halves: Record<string, string>): string {
	return braces(fill(rustFormat(rustBody("engine/targets.rs", opens), name), name, [], halves));
}

/** The registration kendex writes for a project-scope hook, command and all.
 * `env` is what the hook's declaration sets for its script, empty for one that
 * declares none. */
export function registerProjectHook(project: string, name: string, env: Record<string, string> = {}): void {
	registerRendered(join(project, ".pi"), "tool_call", "Bash", projectCommand(`.pi/kendex/hooks/${name}.sh`, env));
}

export function renderUserStub(userRoot: string, name: string, opts: StubOptions, env: Record<string, string> = {}): void {
	const script = join(userRoot, "kendex", "hooks", `${name}.sh`);
	writeStub(script, opts);
	registerRendered(userRoot, "tool_call", "Bash", globalCommand(script, env));
}

/** `reportEnv` names an environment variable the stub appends to its log as
 * `<NAME>=[<value>]`, empty brackets where the spawn set none — for a case
 * whose subject is the environment a registration asks for. */
export interface StubOptions { exitCode: number; stderr?: string; log: string; reportEnv?: string }

function writeStub(path: string, opts: StubOptions): void {
	mkdirSync(join(path, ".."), { recursive: true });
	writeFileSync(path, [
		"#!/usr/bin/env bash",
		"set -euo pipefail",
		`cat >> ${JSON.stringify(opts.log)}`,
		...(opts.reportEnv ? [`printf '${opts.reportEnv}=[%s]\\n' "\${${opts.reportEnv}:-}" >> ${JSON.stringify(opts.log)}`] : []),
		...(opts.stderr ? [`echo ${JSON.stringify(opts.stderr)} >&2`] : []),
		`exit ${opts.exitCode}`,
	].join("\n") + "\n");
	chmodSync(path, 0o755);
}

export function readLog(log: string): string {
	return readFileSync(log, { encoding: "utf8", flag: "a+" });
}

/** A trusted workspace. Pi gates the project's own scripts on this, so every
 * case that expects a project-scope hook to run has to say so. */
export function trusted(cwd: string, extra: Record<string, unknown> = {}): Record<string, unknown> {
	return { cwd, isProjectTrusted: () => true, sessionManager, ...extra };
}

/**
 * A `tool_result` event in the shape Pi fires one: `toolName`, the `input` the
 * call carried, and the `content` blocks the model reads — never absent, which
 * is why every fixture builds the event here rather than by hand.
 */
export function toolResultEvent(toolName: string, input: Record<string, unknown>, text = ""): Record<string, unknown> {
	return { toolName, input, content: text === "" ? [] : [{ type: "text", text }], isError: false };
}
