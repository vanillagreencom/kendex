/**
 * Shared RPC harness for pi integration tests.
 * Provides spawn, send, event waiting, and text collection utilities.
 */
import { spawn } from "node:child_process";
import { createWriteStream, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { StringDecoder } from "node:string_decoder";

const DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

// Auto-load .env.test so int tests work when invoked directly
// (`node --import tsx --test tests/int-foo.mjs`) and not just via `npm test`.
const ENV_FILE = resolve(DIR, ".env.test");
if (existsSync(ENV_FILE)) process.loadEnvFile(ENV_FILE);

/**
 * Create an RPC harness for pi integration tests.
 *
 * @param {Object} opts
 * @param {string} opts.name - Test name (used for log files)
 * @param {string[]} opts.args - Additional pi CLI args (after --mode rpc)
 * @param {Object} opts.env - Extra env vars to set on the pi process
 * @param {number} opts.defaultTimeout - Default timeout for send/wait operations (default: 30000)
 */
export function createRpcHarness(opts) {
	const { name, args = [], env = {}, defaultTimeout = 30_000 } = opts;

	const LOGDIR = `${DIR}/.test-output`;
	mkdirSync(LOGDIR, { recursive: true });

	const RPC_LOG = `${LOGDIR}/${name}.log`;
	const DEBUG_LOG = `${LOGDIR}/${name}-debug.log`;

	// Strip any local node_modules from PATH so we use the globally-installed `pi`.
	const cleanPath = process.env.PATH.split(":").filter((p) => !p.includes("node_modules")).join(":");

	let pi, rpcLog;
	let stopped = false;
	let buffer = "";
	let listeners = [];
	let reqId = 0;
	let childClosed;
	let childFailure;
	let stopping;
	const pending = new Set();

	function start() {
		stopped = false;
		stopping = undefined;
		childFailure = undefined;
		buffer = "";
		// Truncate the debug log on each run so test assertions that grep the
		// log see only this run's output, not accumulated history from prior
		// failing runs. RPC log is still append so cross-run comparisons work.
		writeFileSync(DEBUG_LOG, "");
		rpcLog = createWriteStream(RPC_LOG, { flags: "a" });
		const spawnArgs = ["--no-session", "-ne", "-e", DIR, "--mode", "rpc", ...args];
		pi = spawn("pi", spawnArgs, {
			// Pi owns SDK descendants; a private group lets teardown stop the whole tree.
			detached: process.platform !== "win32",
			stdio: ["pipe", "pipe", "pipe"],
			env: { ...process.env, PATH: cleanPath, CLAUDE_BRIDGE_DEBUG: "1", CLAUDE_BRIDGE_DEBUG_PATH: DEBUG_LOG, ...env },
		});

		childClosed = new Promise((resolve) => pi.once("close", resolve));
		pi.on("error", (error) => {
			childFailure = error;
			for (const cancel of [...pending]) cancel(error);
		});
		pi.on("close", (code, signal) => {
			childFailure ??= new Error(`pi_exit=${code ?? signal}`);
			for (const cancel of [...pending]) cancel(childFailure);
		});

		pi.stderr.on("data", (d) => { if (!stopped) rpcLog.write(d); });

		const decoder = new StringDecoder("utf8");
		pi.stdout.on("data", (chunk) => {
			buffer += decoder.write(chunk);
			while (true) {
				const i = buffer.indexOf("\n");
				if (i === -1) break;
				const line = buffer.slice(0, i);
				buffer = buffer.slice(i + 1);
				try {
					const msg = JSON.parse(line);
					if (!stopped) rpcLog.write(`< ${line}\n`);
					for (const fn of [...listeners]) fn(msg);
				} catch {}
			}
		});
	}

	function signalOwnedProcess(signal) {
		if (process.platform === "win32" || !pi.pid) {
			pi.kill(signal);
			return;
		}
		try {
			process.kill(-pi.pid, signal);
		} catch (error) {
			if (error.code !== "ESRCH") throw error;
		}
	}

	function stop() {
		if (stopping) return stopping;
		stopping = (async () => {
			stopped = true;
			for (const cancel of [...pending]) cancel(new Error("harness_state=stopped"));
			listeners = [];
			if (pi) {
				signalOwnedProcess("SIGTERM");
				const timer = setTimeout(() => signalOwnedProcess("SIGKILL"), 1000);
				try {
					await childClosed;
					// Descendants can close inherited pipes before they exit.
					if (process.platform !== "win32") signalOwnedProcess("SIGKILL");
				} finally {
					clearTimeout(timer);
				}
			}
			if (rpcLog) await new Promise((resolve, reject) => {
				rpcLog.once("error", reject);
				rpcLog.end(resolve);
			});
		})();
		return stopping;
	}

	function addListener(fn) {
		listeners.push(fn);
		return () => {
			const i = listeners.indexOf(fn);
			if (i !== -1) listeners.splice(i, 1);
		};
	}

	function waitForMatch(predicate, description, timeout = defaultTimeout) {
		if (childFailure) return Promise.reject(childFailure);
		if (stopped) return Promise.reject(new Error("harness_state=stopped"));
		return new Promise((resolve, reject) => {
			const finish = (error, msg) => {
				clearTimeout(timer);
				remove();
				pending.delete(cancel);
				if (error) reject(error); else resolve(msg);
			};
			const cancel = (error) => finish(error);
			const timer = setTimeout(() => cancel(new Error(`rpc_timeout=${description}`)), timeout);
			const remove = addListener((msg) => {
				if (predicate(msg)) finish(null, msg);
			});
			pending.add(cancel);
		});
	}

	async function send(cmd, timeout = defaultTimeout) {
		if (childFailure) throw childFailure;
		if (stopped) throw new Error("harness_state=stopped");
		const id = `req_${++reqId}`;
		const full = { ...cmd, id };
		const response = waitForMatch((msg) => msg.type === "response" && msg.id === id, cmd.type, timeout);
		if (!stopped) rpcLog.write(`> ${JSON.stringify(full)}\n`);
		pi.stdin.write(JSON.stringify(full) + "\n");
		const msg = await response;
		if (!msg.success) throw new Error(`rpc_command=${cmd.type}\n${msg.error}`);
		return msg.data;
	}

	function waitForEvent(type, timeout = defaultTimeout) {
		return waitForMatch((msg) => msg.type === type, type, timeout);
	}

	function collectText() {
		let text = "";
		const handler = (msg) => {
			if (msg.type === "message_update") {
				const ae = msg.assistantMessageEvent;
				if (ae?.type === "text_delta") text += ae.delta;
			}
		};
		addListener(handler);
		return { stop() { const i = listeners.indexOf(handler); if (i !== -1) listeners.splice(i, 1); return text; } };
	}

	async function promptAndWait(message, timeout = defaultTimeout) {
		const collector = collectText();
		try {
			await Promise.all([waitForEvent("agent_end", timeout), send({ type: "prompt", message }, timeout)]);
			return collector.stop();
		} finally {
			collector.stop();
		}
	}


	return {
		DIR,
		LOGDIR,
		RPC_LOG,
		DEBUG_LOG,
		pi: () => pi,
		start,
		stop,
		addListener,
		send,
		waitForEvent,
		waitForMatch,
		collectText,
		promptAndWait,
	};
}

/**
 * Require environment variable or exit with error.
 * @param {string} name - Environment variable name
 * @returns {string} The env var value
 */
export function requireEnv(name) {
	const value = process.env[name];
	if (!value) {
		console.error(`missing_env=${name}\nSet the environment variable in .env.test.`);
		process.exit(1);
	}
	return value;
}
