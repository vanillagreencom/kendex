#!/usr/bin/env node
/*
 * Minimal client for .pi/extensions/session-bridge.
 * Speaks strict LF-delimited JSON over a Unix-domain socket.
 */

const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");

const PROTOCOL = "pi-session-bridge.v1";

function usage(exitCode = 0) {
	const out = exitCode === 0 ? process.stdout : process.stderr;
	out.write(`Usage:
  pi-bridge list [--json] [--all]
  pi-bridge state [--pid PID|--socket PATH|--session TEXT|--name TEXT|--cwd TEXT]
  pi-bridge commands [target]
  pi-bridge send [target] [--auto|--steer|--follow-up|--now] MESSAGE...
  pi-bridge steer [target] MESSAGE...
  pi-bridge follow-up [target] MESSAGE...
  pi-bridge stream [target]
  pi-bridge history [target] [LIMIT] [--raw|--verbose] [--event NAME] [--since TS] [--max-bytes N]
  pi-bridge questions [target]
  pi-bridge answer [target] --request-id que_... --answers '[["Label"]]'
  pi-bridge reject [target] --request-id que_...
  pi-bridge emit [target] MESSAGE...
  pi-bridge request [target] '{"type":"get_state"}'

Target options:
  --pid PID        Match a bridge process id
  --socket PATH    Connect to an explicit Unix socket
  --session TEXT   Substring match session id or session file
  --name TEXT      Substring match session name
  --cwd TEXT       Substring match cwd
  --bridge-dir DIR Override PI_BRIDGE_DIR/default discovery dir

History options:
  --raw / --verbose  Rehydrate compact events from the per-session sidecar JSONL.
  --event NAME       Filter to one event name (e.g. message_update, tool_execution_end).
  --since TS         Return only events with timestamp >= TS (ISO 8601).
  --max-bytes N      Cap response payload size in bytes (default ~1 MiB).

Environment:
  PI_BRIDGE_DIR    Default: /tmp/pi-session-bridge-$UID
`);
	process.exit(exitCode);
}

function bridgeDir(opts = {}) {
	if (opts.bridgeDir) return path.resolve(opts.bridgeDir);
	if (process.env.PI_BRIDGE_DIR) return path.resolve(process.env.PI_BRIDGE_DIR);
	const uid = typeof process.getuid === "function" ? process.getuid() : os.userInfo().username;
	return path.join(os.tmpdir(), `pi-session-bridge-${uid}`);
}

function parse(argv) {
	const opts = {};
	const rest = [];
	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];
		switch (arg) {
			case "-h":
			case "--help":
				usage(0);
				break;
			case "--json":
				opts.json = true;
				break;
			case "--all":
				opts.all = true;
				break;
			case "--raw":
				opts.raw = true;
				break;
			case "-v":
			case "--verbose":
				opts.verbose = true;
				break;
			case "--auto":
				opts.deliverAs = "auto";
				break;
			case "--steer":
				opts.deliverAs = "steer";
				break;
			case "--follow-up":
			case "--followUp":
				opts.deliverAs = "followUp";
				break;
			case "--now":
				opts.deliverAs = "now";
				break;
			case "--pid":
			case "--socket":
			case "--session":
			case "--name":
			case "--cwd":
			case "--request-id":
			case "--answers":
			case "--bridge-dir":
			case "--event":
			case "--since":
			case "--max-bytes": {
				const value = argv[++i];
				if (!value) die(`Missing value for ${arg}`);
				opts[arg.slice(2).replace(/-([a-z])/g, (_, ch) => ch.toUpperCase())] = value;
				break;
			}
			default:
				rest.push(arg);
		}
	}
	return { opts, rest };
}

function die(message) {
	process.stderr.write(`${message}\n`);
	process.exit(1);
}

function isAlive(pid) {
	const numeric = Number(pid);
	if (!Number.isInteger(numeric) || numeric <= 0) return false;
	try {
		process.kill(numeric, 0);
		return true;
	} catch (error) {
		return error && error.code === "EPERM";
	}
}

function loadInstances(opts = {}) {
	const dir = path.join(bridgeDir(opts), "instances");
	let files = [];
	try {
		files = fs.readdirSync(dir).filter((file) => file.endsWith(".json"));
	} catch (error) {
		if (error.code === "ENOENT") return [];
		throw error;
	}
	return files
		.map((file) => {
			try {
				const info = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
				info.alive = isAlive(info.pid);
				info.socketExists = typeof info.socketPath === "string" && fs.existsSync(info.socketPath);
				info.stale = !info.alive || !info.socketExists || info.protocol !== PROTOCOL;
				return info;
			} catch {
				return undefined;
			}
		})
		.filter(Boolean)
		.filter((info) => opts.all || !info.stale)
		.sort((a, b) => String(a.pid).localeCompare(String(b.pid)));
}

function printInstances(instances, json = false) {
	if (json) {
		process.stdout.write(`${JSON.stringify(instances, null, 2)}\n`);
		return;
	}
	if (instances.length === 0) {
		process.stdout.write("No active pi session bridges found.\n");
		return;
	}
	process.stdout.write("PID\tIDLE\tSESSION\tNAME\tCWD\tSOCKET\n");
	for (const info of instances) {
		process.stdout.write(
			[
				info.pid,
				info.isIdle === undefined ? "?" : info.isIdle ? "yes" : "no",
				short(info.sessionId || "-", 8),
				info.sessionName || "-",
				info.cwd || "-",
				info.socketPath || "-",
			].join("\t") + "\n",
		);
	}
}

function short(text, len) {
	return String(text).length > len ? String(text).slice(0, len) : String(text);
}

function selectTarget(opts) {
	if (opts.socket) return { socketPath: opts.socket };
	let matches = loadInstances(opts);
	if (opts.pid) matches = matches.filter((info) => String(info.pid) === String(opts.pid));
	if (opts.session) {
		matches = matches.filter((info) => includes(info.sessionId, opts.session) || includes(info.sessionFile, opts.session));
	}
	if (opts.name) matches = matches.filter((info) => includes(info.sessionName, opts.name));
	if (opts.cwd) matches = matches.filter((info) => includes(info.cwd, opts.cwd));
	if (matches.length === 1) return matches[0];
	if (matches.length === 0) die("No matching active pi session bridge. Use `tools/pi-bridge list`.");
	printInstances(matches);
	die("Multiple matching pi session bridges. Add --pid, --session, --name, or --socket.");
}

function includes(value, needle) {
	return typeof value === "string" && value.includes(String(needle));
}

function request(target, command, options = {}) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection(target.socketPath);
		let buffer = "";
		let settled = false;
		const wantId = command.id;

		socket.setEncoding("utf8");
		socket.on("connect", () => {
			socket.write(`${JSON.stringify(command)}\n`);
		});
		socket.on("data", (chunk) => {
			buffer += chunk;
			while (true) {
				const newline = buffer.indexOf("\n");
				if (newline === -1) break;
				let line = buffer.slice(0, newline);
				buffer = buffer.slice(newline + 1);
				if (line.endsWith("\r")) line = line.slice(0, -1);
				if (!line) continue;

				if (options.stream) {
					process.stdout.write(`${line}\n`);
					continue;
				}

				let msg;
				try {
					msg = JSON.parse(line);
				} catch {
					continue;
				}
				if (msg.type === "response" && msg.id === wantId) {
					settled = true;
					process.stdout.write(`${JSON.stringify(msg, null, 2)}\n`);
					socket.end();
					resolve(msg.success ? 0 : 1);
				}
			}
		});
		socket.on("error", reject);
		socket.on("close", () => {
			if (!settled && !options.stream) reject(new Error("Socket closed before response"));
		});
	});
}

async function main() {
	const [command, ...argv] = process.argv.slice(2);
	if (!command || command === "help" || command === "--help" || command === "-h") usage(command ? 0 : 1);
	const { opts, rest } = parse(argv);

	if (command === "list") {
		printInstances(loadInstances(opts), opts.json);
		return;
	}

	const target = selectTarget(opts);
	const id = `${Date.now()}-${Math.random().toString(16).slice(2)}`;

	if (command === "stream") {
		await request(target, { id, type: "subscribe", enabled: true }, { stream: true });
		return;
	}

	if (command === "state") {
		process.exitCode = await request(target, { id, type: "get_state" });
		return;
	}

	if (command === "commands") {
		process.exitCode = await request(target, { id, type: "get_commands" });
		return;
	}

	if (command === "history") {
		const limit = rest[0] ? Number.parseInt(rest[0], 10) : undefined;
		const cmd = { id, type: "history" };
		if (limit !== undefined && Number.isFinite(limit)) cmd.limit = limit;
		if (opts.raw || opts.verbose) cmd.raw = true;
		if (opts.event) cmd.event = opts.event;
		if (opts.since) cmd.since = opts.since;
		if (opts.maxBytes) {
			const parsed = Number.parseInt(opts.maxBytes, 10);
			if (Number.isFinite(parsed) && parsed > 0) cmd.maxBytes = parsed;
		}
		process.exitCode = await request(target, cmd);
		return;
	}

	if (command === "questions" || command === "question-list") {
		process.exitCode = await request(target, { id, type: "questions" });
		return;
	}

	if (command === "answer" || command === "reply") {
		if (!opts.requestId) die(`Missing --request-id for ${command}`);
		const answersText = opts.answers || rest.join(" ").trim();
		if (!answersText) die(`Missing --answers for ${command}`);
		let answers;
		try {
			answers = JSON.parse(answersText);
		} catch (error) {
			die(`Invalid --answers JSON: ${error.message}`);
		}
		process.exitCode = await request(target, { id, type: "answer", requestId: opts.requestId, answers });
		return;
	}

	if (command === "reject") {
		if (!opts.requestId) die("Missing --request-id for reject");
		process.exitCode = await request(target, { id, type: "reject", requestId: opts.requestId });
		return;
	}

	if (command === "emit") {
		process.exitCode = await request(target, { id, type: "emit", message: rest.join(" ").trim() || "test" });
		return;
	}

	if (command === "request" || command === "raw") {
		const text = rest.join(" ").trim();
		const jsonText = text === "-" ? fs.readFileSync(0, "utf8").trim() : text;
		if (!jsonText) die(`Missing JSON command for ${command}`);
		let raw;
		try {
			raw = JSON.parse(jsonText);
		} catch (error) {
			die(`Invalid JSON command: ${error.message}`);
		}
		if (!raw || typeof raw !== "object" || Array.isArray(raw)) die("JSON command must be an object");
		if (!raw.id) raw.id = id;
		if (typeof raw.type !== "string" || raw.type.length === 0) die("JSON command must include a string type");
		process.exitCode = await request(target, raw);
		return;
	}

	if (command === "send" || command === "steer" || command === "follow-up" || command === "followUp") {
		const message = rest.join(" ").trim();
		if (!message) die(`Missing message for ${command}`);
		const type = command === "steer" ? "steer" : command === "follow-up" || command === "followUp" ? "follow_up" : "prompt";
		process.exitCode = await request(target, {
			id,
			type,
			message,
			deliverAs: opts.deliverAs,
		});
		return;
	}

	die(`Unknown command: ${command}`);
}

main().catch((error) => die(error.stack || error.message || String(error)));
