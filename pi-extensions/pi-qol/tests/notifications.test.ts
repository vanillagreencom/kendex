import { afterEach, beforeEach, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { closeSync, constants, mkdtempSync, openSync, readSync, rmSync, writeFileSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { clearTmuxWindowMark, osc777NotificationSequence, sendQolNotification, terminalBellSequence } from "../extensions/qol/notifications.ts";

const bellRows = [
	{ name: "audible terminal bell", muted: false, expected: "\x07" },
	{ name: "muted terminal bell", muted: true, expected: undefined },
];

if (bellRows.length === 0) throw new Error("Terminal bell table is empty");

for (const row of bellRows) {
	test(row.name, () => {
		expect.hasAssertions();
		expect(terminalBellSequence(row.muted)).toBe(row.expected);
	});
}

const oscRows = [
	{ name: "default OSC BEL terminator", muted: undefined, expected: { sequence: "\x1b]777;notify;Title;Body\x07", containsBell: true } },
	{ name: "muted OSC ST terminator", muted: true, expected: { sequence: "\x1b]777;notify;Title;Body\x1b\\", containsBell: false } },
];

if (oscRows.length === 0) throw new Error("OSC notification table is empty");

for (const row of oscRows) {
	test(row.name, () => {
		expect.hasAssertions();
		const sequence = osc777NotificationSequence("Title", "Body", row.muted);
		expect({ sequence, containsBell: sequence.includes("\x07") }).toEqual(row.expected);
	});
}

// ---- delivery: tmux calls and terminal writes ----

interface ExecCall {
	command: string;
	args: string[];
	timeout: number | undefined;
}

type TmuxAnswer = { code: number; killed: boolean; stdout: string } | "stall";

const PANE_STATE_FORMAT = "#{pane_tty}\t#{window_active}\t#{session_id}\t#{window_id}\t#W";

/** tmux's answer to the pane-state query, in `PANE_STATE_FORMAT` order. */
function paneState(paneTty: string, { active = false, sessionId = "$3", windowId = "@7", windowName = "pi" } = {}): TmuxAnswer {
	return { code: 0, killed: false, stdout: `${paneTty}\t${active ? 1 : 0}\t${sessionId}\t${windowId}\t${windowName}\n` };
}

/** A fake `pi.exec` answering tmux: the pane-state query takes `paneStates` in order, list-clients answers `clientTty` or stalls. */
function fakeTmux(clientTty: string | "stall", paneStates: TmuxAnswer[]) {
	const calls: ExecCall[] = [];
	const exec = async (command: string, args: string[], options?: { timeout?: number }) => {
		calls.push({ command, args, timeout: options?.timeout });
		let answer: TmuxAnswer = { code: 0, killed: false, stdout: "" };
		if (args[0] === "display-message" && args.at(-1) === PANE_STATE_FORMAT) answer = paneStates.shift() ?? { code: 1, killed: false, stdout: "" };
		else if (args[0] === "list-clients") answer = clientTty === "stall" ? "stall" : { code: 0, killed: false, stdout: `${clientTty}\n` };
		if (answer === "stall") return new Promise<never>(() => {});
		return { ...answer, stderr: "" };
	};
	return { calls, pi: { exec } as never };
}

const argsOf = (calls: ExecCall[], subcommand: string) => calls.filter((call) => call.args[0] === subcommand).map((call) => call.args);

let root = "";
let keySeq = 0;
const nextKey = () => `delivery-${++keySeq}`;
const readers: number[] = [];
const savedEnv: Record<string, string | undefined> = {};
const ENV_KEYS = ["HOME", "PI_CODING_AGENT_DIR", "TMUX", "TMUX_PANE", "WT_SESSION", "KITTY_WINDOW_ID"];

/** A FIFO with a reader that reads only when asked: a tty that takes writes without the test stepping it. */
function fakeTty(name: string) {
	const path = join(root, name);
	execFileSync("mkfifo", ["--", path]);
	const fd = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK);
	readers.push(fd);
	const read = () => {
		const chunk = Buffer.alloc(1 << 16);
		let out = "";
		for (;;) {
			let size = 0;
			try {
				size = readSync(fd, chunk);
			} catch (error) {
				if ((error as NodeJS.ErrnoException).code === "EAGAIN") break;
				throw error;
			}
			if (size === 0) break;
			out += chunk.toString("utf8", 0, size);
		}
		return out;
	};
	return { path, read };
}

/** A tty whose reader never drains it, as a tmux client behind a dropped SSH link: its buffer is full. */
function stalledTty(name: string): string {
	const { path } = fakeTty(name);
	const writer = openSync(path, constants.O_WRONLY | constants.O_NONBLOCK);
	try {
		for (;;) writeSync(writer, Buffer.alloc(4096));
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "EAGAIN") throw error;
	} finally {
		closeSync(writer);
	}
	return path;
}

function writeQolSettings(config: Record<string, unknown>): void {
	writeFileSync(join(root, "settings.json"), `${JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-qol": config } } } })}\n`, "utf8");
}

/** Settles with "stalled" when `promise` has not settled within `ms`. */
function within<T>(promise: Promise<T>, ms: number): Promise<T | "stalled"> {
	return Promise.race([promise, new Promise<"stalled">((resolve) => setTimeout(() => resolve("stalled"), ms))]);
}

beforeEach(() => {
	root = mkdtempSync(join(tmpdir(), "pi-qol-notifications-"));
	for (const key of ENV_KEYS) savedEnv[key] = process.env[key];
	process.env.HOME = root;
	process.env.PI_CODING_AGENT_DIR = root;
	process.env.TMUX = "/tmp/tmux-test/default,1,0";
	process.env.TMUX_PANE = "%1";
	delete process.env.WT_SESSION;
	delete process.env.KITTY_WINDOW_ID;
});

afterEach(() => {
	clearTmuxWindowMark(fakeTmux("", []).pi);
	for (const fd of readers.splice(0)) closeSync(fd);
	for (const key of ENV_KEYS) {
		if (savedEnv[key] === undefined) delete process.env[key];
		else process.env[key] = savedEnv[key];
	}
	if (root) rmSync(root, { force: true, recursive: true });
});

test("every tmux call carries a deadline, and a stalled tmux leaves the caller free", () => {
	expect.hasAssertions();
	const { calls, pi } = fakeTmux("", ["stall"]);
	const delivery = sendQolNotification(pi, undefined, "test", "body", "info", nextKey());
	expect({ returned: delivery instanceof Promise, timeouts: calls.map((call) => call.timeout) }).toEqual({ returned: true, timeouts: [1000] });
});

test("the bell goes to the source pane tty and the OSC notification to the pane's session's client tty", async () => {
	expect.hasAssertions();
	const pane = fakeTty("pane-tty");
	const client = fakeTty("client-tty");
	const { calls, pi } = fakeTmux(client.path, [paneState(pane.path, { sessionId: "$5" })]);
	await sendQolNotification(pi, undefined, "test", "body", "info", nextKey());
	expect({ pane: pane.read(), client: client.read(), listClients: argsOf(calls, "list-clients") }).toEqual({
		pane: "\x07",
		client: osc777NotificationSequence("Pi", "body"),
		listClients: [["list-clients", "-t", "$5", "-F", "#{client_tty}"]],
	});
});

test("a tmux answer its deadline killed counts as no answer", async () => {
	expect.hasAssertions();
	writeQolSettings({ "notification.bell": false });
	const client = fakeTty("client-tty");
	// Pi's exec reports a killed command with code 0 when the signal left no exit status.
	const killed: TmuxAnswer = { ...(paneState(join(root, "pane-tty")) as { stdout: string }), code: 0, killed: true };
	const { calls, pi } = fakeTmux(client.path, [killed]);
	await sendQolNotification(pi, undefined, "test", "body", "info", nextKey());
	expect(argsOf(calls, "list-clients")).toEqual([["list-clients", "-F", "#{client_tty}"]]);
});

test("the window mark renames the pane's window as tmux reports it at each notification, and clearing names it back", async () => {
	expect.hasAssertions();
	writeQolSettings({ "notification.tmuxWindowMark": true, "notification.bell": false, "notification.native": false });
	// Between the two notifications tmux break-pane moved Pi's pane from @7 to a new window @8.
	const paneTty = join(root, "pane-tty");
	const { calls, pi } = fakeTmux("", [paneState(paneTty, { windowId: "@7", windowName: "editor" }), paneState(paneTty, { windowId: "@8", windowName: "pi" })]);
	await sendQolNotification(pi, undefined, "test", "first", "info", nextKey());
	await sendQolNotification(pi, undefined, "test", "second", "info", nextKey());
	clearTmuxWindowMark(pi);
	expect(argsOf(calls, "rename-window")).toEqual([
		["rename-window", "-t", "@7", "! editor"],
		["rename-window", "-t", "@7", "editor"],
		["rename-window", "-t", "@8", "! pi"],
		["rename-window", "-t", "@8", "pi"],
	]);
});

test("a window mark cleared while its notification is in flight is not set", async () => {
	expect.hasAssertions();
	writeQolSettings({ "notification.tmuxWindowMark": true, "notification.bell": false, "notification.native": false });
	const { calls, pi } = fakeTmux("", [paneState(join(root, "pane-tty"), { windowName: "pi" })]);
	const delivery = sendQolNotification(pi, undefined, "test", "body", "info", nextKey());
	// The user switches in and submits before tmux answers the pane-state query.
	clearTmuxWindowMark(pi);
	await delivery;
	expect(argsOf(calls, "rename-window")).toEqual([]);
});

test("the window mark and the tmux message do not wait on the terminal writes", async () => {
	expect.hasAssertions();
	writeQolSettings({ "notification.tmuxWindowMark": true, "notification.tmux": true, "notification.bell": false });
	// list-clients never answers, so the native notification's write never starts.
	const { calls, pi } = fakeTmux("stall", [paneState(join(root, "pane-tty"), { windowName: "pi" })]);
	// Real wait: bounds a delivery that cannot settle while list-clients stalls.
	const settled = await within(sendQolNotification(pi, undefined, "test", "body", "info", nextKey()), 50);
	expect({ settled, rename: argsOf(calls, "rename-window"), tmuxMessages: argsOf(calls, "display-message").filter((args) => args[1] === "-d").map((args) => args.at(-1)) }).toEqual({
		settled: "stalled",
		rename: [["rename-window", "-t", "@7", "! pi"]],
		tmuxMessages: ["Pi: body"],
	});
});

/**
 * A full tty on each write path: the pane tty takes the bell by `writeToTerminal`,
 * a client tty takes the OSC by `writeRawToPaths`. The other tty drains and
 * receives each notification's OSC: straight to the client, or through the
 * pane's fallback once the stalled client refuses it.
 */
const stalledTtyRows = [
	{ stalled: "pane" as const, settings: { "notification.tmux": true } },
	{ stalled: "client" as const, settings: { "notification.tmux": true, "notification.bell": false, "notification.tmuxPassthrough": false } },
];

if (stalledTtyRows.length === 0) throw new Error("Stalled tty table is empty");

for (const row of stalledTtyRows) {
	test(`a ${row.stalled} tty that never drains leaves later notifications' OSC and tmux messages free`, async () => {
		expect.hasAssertions();
		writeQolSettings(row.settings);
		const stalled = stalledTty(`${row.stalled}-tty`);
		const draining = fakeTty(row.stalled === "pane" ? "client-tty" : "pane-tty");
		const [pane, client] = row.stalled === "pane" ? [stalled, draining.path] : [draining.path, stalled];
		// The first notification's window is inactive, so it rings the bell when the
		// bell is on; the second's is active, so it writes only the OSC.
		const { calls, pi } = fakeTmux(client, [paneState(pane), paneState(pane, { active: true })]);
		// Real wait: bounds a delivery that a blocking write to the full tty never settles.
		const first = within(sendQolNotification(pi, undefined, "test", "first", "info", nextKey()), 2000);
		const second = within(sendQolNotification(pi, undefined, "test", "second", "info", nextKey()), 2000);
		const settled = await Promise.all([first, second]);
		const written = draining.read();
		expect({
			settled,
			osc: { first: written.includes(osc777NotificationSequence("Pi", "first")), second: written.includes(osc777NotificationSequence("Pi", "second")) },
			tmuxMessages: argsOf(calls, "display-message").filter((args) => args[1] === "-d").map((args) => args.at(-1)),
		}).toEqual({
			settled: [undefined, undefined],
			osc: { first: true, second: true },
			tmuxMessages: ["Pi: first", "Pi: second"],
		});
	});
}
