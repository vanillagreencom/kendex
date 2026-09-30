import { afterEach, beforeEach, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { closeSync, constants, existsSync, mkdtempSync, openSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { forgetTmuxIdentity, osc777NotificationSequence, sendQolNotification, terminalBellSequence } from "../extensions/qol/notifications.ts";

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

const IDENTITY_FORMAT = "#{pane_tty}\t#{session_id}\t#{window_id}";

/** A fake `pi.exec` answering tmux by subcommand; `answers` overrides a query per call, in order. */
function fakeTmux(paneTty: string, clientTty: string, answers: { identity?: TmuxAnswer[]; windowActive?: TmuxAnswer[] } = {}) {
	const calls: ExecCall[] = [];
	const ok = (stdout: string): TmuxAnswer => ({ code: 0, killed: false, stdout });
	const exec = async (command: string, args: string[], options?: { timeout?: number }) => {
		calls.push({ command, args, timeout: options?.timeout });
		const format = args.at(-1);
		let answer: TmuxAnswer = { code: 0, killed: false, stdout: "" };
		if (args[0] === "display-message" && format === IDENTITY_FORMAT) answer = answers.identity?.shift() ?? ok(`${paneTty}\t$3\t@7\n`);
		else if (args[0] === "display-message" && format === "#{window_active}") answer = answers.windowActive?.shift() ?? ok("0\n");
		else if (args[0] === "list-clients") answer = ok(`${clientTty}\n`);
		if (answer === "stall") return new Promise<never>(() => {});
		return { ...answer, stderr: "" };
	};
	return { calls, pi: { exec } as never };
}

const identityLookups = (calls: ExecCall[]) => calls.filter((call) => call.args.at(-1) === IDENTITY_FORMAT).length;

let root = "";
let keySeq = 0;
const nextKey = () => `delivery-${++keySeq}`;
const savedEnv: Record<string, string | undefined> = {};
const ENV_KEYS = ["HOME", "PI_CODING_AGENT_DIR", "TMUX", "TMUX_PANE", "WT_SESSION", "KITTY_WINDOW_ID"];

beforeEach(() => {
	root = mkdtempSync(join(tmpdir(), "pi-qol-notifications-"));
	for (const key of ENV_KEYS) savedEnv[key] = process.env[key];
	process.env.HOME = root;
	process.env.PI_CODING_AGENT_DIR = root;
	process.env.TMUX = "/tmp/tmux-test/default,1,0";
	process.env.TMUX_PANE = "%1";
	delete process.env.WT_SESSION;
	delete process.env.KITTY_WINDOW_ID;
	forgetTmuxIdentity();
});

afterEach(() => {
	forgetTmuxIdentity();
	for (const key of ENV_KEYS) {
		if (savedEnv[key] === undefined) delete process.env[key];
		else process.env[key] = savedEnv[key];
	}
	if (root) rmSync(root, { force: true, recursive: true });
});

test("every tmux call carries a deadline, and a stalled tmux leaves the caller free", () => {
	expect.hasAssertions();
	const { calls, pi } = fakeTmux("", "", { identity: ["stall"], windowActive: ["stall"] });
	const delivery = sendQolNotification(pi, undefined, "test", "body", "info", nextKey());
	expect({ returned: delivery instanceof Promise, timeouts: calls.map((call) => call.timeout) }).toEqual({ returned: true, timeouts: [1000, 1000] });
});

test("the bell goes to the source pane tty and the OSC notification to the client tty", async () => {
	expect.hasAssertions();
	const paneTty = join(root, "pane-tty");
	const clientTty = join(root, "client-tty");
	const { pi } = fakeTmux(paneTty, clientTty);
	await sendQolNotification(pi, undefined, "test", "body", "info", nextKey());
	expect({ pane: readFileSync(paneTty, "utf8"), client: readFileSync(clientTty, "utf8") }).toEqual({ pane: "\x07", client: osc777NotificationSequence("Pi", "body") });
});

test("the tmux identity is looked up once per session, and a failed lookup is retried", async () => {
	expect.hasAssertions();
	const failed: TmuxAnswer = { code: 1, killed: false, stdout: "" };
	const { calls, pi } = fakeTmux(join(root, "pane-tty"), join(root, "client-tty"), { identity: [failed] });
	await sendQolNotification(pi, undefined, "test", "body", "info", nextKey());
	await sendQolNotification(pi, undefined, "test", "body", "info", nextKey());
	await sendQolNotification(pi, undefined, "test", "body", "info", nextKey());
	const withinSession = identityLookups(calls);
	forgetTmuxIdentity();
	await sendQolNotification(pi, undefined, "test", "body", "info", nextKey());
	expect({ withinSession, afterForget: identityLookups(calls) }).toEqual({ withinSession: 2, afterForget: 3 });
});

test("a tmux answer its deadline killed counts as no answer", async () => {
	expect.hasAssertions();
	const paneTty = join(root, "pane-tty");
	// Pi's exec reports a killed command with code 0 when the signal left no exit status.
	const killedActive: TmuxAnswer = { code: 0, killed: true, stdout: "1\n" };
	const { pi } = fakeTmux(paneTty, join(root, "client-tty"), { windowActive: [killedActive] });
	await sendQolNotification(pi, undefined, "test", "body", "info", nextKey());
	expect(readFileSync(paneTty, "utf8")).toBe("\x07");
});

test("a terminal write waits behind a stalled one instead of running beside it", async () => {
	expect.hasAssertions();
	const paneTty = join(root, "pane-fifo");
	const clientTty = join(root, "client-tty");
	execFileSync("mkfifo", ["--", paneTty]);
	// The first notification's window is inactive, so it rings the bell into a
	// FIFO nobody reads: that open blocks the way a stalled terminal does. The
	// second's window is active, so its only write is the OSC to the client tty.
	const { pi } = fakeTmux(paneTty, clientTty, { windowActive: [{ code: 0, killed: false, stdout: "0\n" }, { code: 0, killed: false, stdout: "1\n" }] });
	let reader: number | undefined;
	try {
		const first = sendQolNotification(pi, undefined, "test", "first", "info", nextKey());
		const second = sendQolNotification(pi, undefined, "test", "second", "info", nextKey());
		// Real wait: the writes run on the runtime's I/O threads, which this test cannot step.
		await new Promise((resolve) => setTimeout(resolve, 150));
		const whileStalled = existsSync(clientTty);
		reader = openSync(paneTty, constants.O_RDONLY | constants.O_NONBLOCK);
		await Promise.all([first, second]);
		// The queue runs writes in the order they were queued: the first bell, the
		// second's OSC, then the first's OSC, queued once its bell finished.
		expect({ whileStalled, lastWrite: readFileSync(clientTty, "utf8") }).toEqual({ whileStalled: false, lastWrite: osc777NotificationSequence("Pi", "first") });
	} finally {
		if (reader === undefined) reader = openSync(paneTty, constants.O_RDONLY | constants.O_NONBLOCK);
		closeSync(reader);
	}
});
