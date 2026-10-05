import { afterAll, beforeAll, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { clearPackageConfigCache } from "../extensions/package-config.ts";
import { CONFIG_ID, projectCommand, registerRendered, runGit, useIsolatedGitEnv } from "./harness.ts";
import { startSession } from "./pi-session.ts";

/**
 * An overseer's mail reaches a Pi lane through the lane's own Pi session, run
 * here in process on the Pi this package's test script installs: this package
 * loaded from its manifest, a scripted model, orch's `lane-mail` doing every
 * read and write, and the lane-mail hooks kendex renders for Pi, whose judge
 * the wake runs. The model runs a command only where a row's opening prompt
 * names one, and answers everything else at once.
 *
 * The turn before the mail ends on a `Stop` hook that speaks, the ending the
 * lanes that never woke had in common: a carrier that held the session inside
 * its settle left no wake of any kind able to start a turn.
 */

useIsolatedGitEnv();

const PACKAGE = join(import.meta.dir, "..");
const REPO = join(PACKAGE, "../..");
// Spelled whole, so the CI selection that searches for `skills/orch` finds this suite.
const ORCH_SCRIPTS = join(PACKAGE, "../../skills/orch/scripts");
const LANE_MAIL = join(ORCH_SCRIPTS, "lane-mail");
const ITEM = "KEN-7";
const WORK = "Work the item, then wait for your overseer.";
const NEXT = "Continue.";

/** lane-mail watch's default --interval, the delay a directive to a lane with a live monitor waits at most. */
const MAIL_INTERVAL_MS = 5_000;

let world: string;
beforeAll(() => {
	world = realpathSync(mkdtempSync(join(tmpdir(), "pi-hooks-lane-wake-")));
});
afterAll(() => rmSync(world, { recursive: true, force: true }));

/**
 * A launched lane as `lane-marker` records one, with the orch scripts and the
 * project-scope lane-mail hooks a kendex install renders, and a user scope
 * whose `Stop` hook says its piece once and stands down on the dispatch at
 * the end of the continuation it caused, as a once-per-finding stop hook does. `stands` is
 * the nearest directory to the lane's mailbox that the lane holds when its
 * session starts.
 */
function laneWorld(name: string, stands: Stands, enabled: boolean): { lane: string; agentDir: string } {
	const lane = join(world, name);
	mkdirSync(lane, { recursive: true });
	runGit(["init", "-q", "-b", ITEM.toLowerCase()], lane);
	// No background maintenance to race the removal in afterAll.
	runGit(["config", "gc.auto", "0"], lane);
	runGit(["config", "maintenance.auto", "false"], lane);
	runGit(["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base"], lane);
	mkdirSync(join(lane, ".agents", "skills", "orch"), { recursive: true });
	symlinkSync(ORCH_SCRIPTS, join(lane, ".agents", "skills", "orch", "scripts"));
	if (stands === "mailbox") mkdirSync(join(lane, "tmp", "lane-mail", ITEM), { recursive: true });
	if (stands === "tmp") mkdirSync(join(lane, "tmp"));
	mkdirSync(join(lane, ".git", "lane-mail"), { recursive: true });
	writeFileSync(join(lane, ".git", "lane-mail", ITEM.toLowerCase()), `${lane}\n`);
	mkdirSync(join(lane, ".pi", "kendex", "hooks"), { recursive: true });
	for (const hook of ["lane-mail-check", "lane-mail-deliver"]) {
		copyFileSync(join(REPO, ".pi", "kendex", "hooks", `${hook}.sh`), join(lane, ".pi", "kendex", "hooks", `${hook}.sh`));
	}
	registerRendered(join(lane, ".pi"), "tool_result", undefined, projectCommand(".pi/kendex/hooks/lane-mail-deliver.sh"), 30);
	const agentDir = join(world, `${name}-agent`);
	mkdirSync(agentDir, { recursive: true });
	registerRendered(agentDir, "turn_end", undefined, `grep -q '"stop_hook_active":true' && exit 0; echo 'stop-check: handle each, then finish.' >&2; exit 2`);
	writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: { enabled, sessionDriftCheck: false } } } } }));
	return { lane, agentDir };
}

function laneMail(lane: string, ...args: string[]): string {
	const run = spawnSync(LANE_MAIL, args, { cwd: lane, encoding: "utf8", env: process.env });
	if (run.status !== 0) throw new Error(`lane-mail ${args.join(" ")} exited ${run.status}: ${run.stderr}`);
	return run.stdout;
}

/** The receipt oversee-watch reads: the directive is read once the lane's cursor passes its line. */
function directiveState(lane: string, id: string): "directive-read" | "directive-unread" {
	const receipts = laneMail(lane, "drain", "--item", ITEM, "--root", lane, "--after", "0", "--receipts").split("\n");
	const cursor = /^receipts cursor=(\d+) /.exec(receipts.find((line) => line.startsWith("receipts ")) ?? "");
	if (cursor === null) throw new Error(`lane-mail drain --receipts printed no cursor:\n${receipts.join("\n")}`);
	const row = receipts.find((line) => line.split(" ")[1] === id);
	if (row === undefined) throw new Error(`lane-mail drain --receipts lists no directive ${id}`);
	return Number(row.split(" ")[0]) <= Number(cursor[1]) ? "directive-read" : "directive-unread";
}

/** The overseer's side: what it sends the lane, and the id the lane's cursor is judged on. */
function send(lane: string, mail: "directive" | "answer"): string {
	writeFileSync(join(world, "mail.txt"), "Stop after this round.\n");
	let kind = ["--directive"];
	if (mail === "answer") {
		const asked = /^id=(\S+)$/m.exec(laneMail(lane, "ask", "--item", ITEM, "--file", join(world, "mail.txt")))?.[1];
		if (asked === undefined) throw new Error("lane-mail ask printed no id");
		kind = ["--re", asked];
	}
	const sent = laneMail(lane, "send", "--item", ITEM, "--root", lane, ...kind, "--file", join(world, "mail.txt"));
	const id = /^lane-mail: sent item=\S+ id=(\S+) /.exec(sent)?.[1];
	if (id === undefined) throw new Error(`lane-mail send printed no receipt: ${sent}`);
	return id;
}

/**
 * The extension entries a row loads. The control's copy keeps the watch above
 * a missing mailbox directory standing and drops the re-arm its changes call.
 */
function entryPaths(entries: Row["entries"], name: string): string[] {
	if (entries === "manifest") return [PACKAGE];
	if (entries === "carrier") return [join(PACKAGE, "extensions", "hooks.ts")];
	const copy = join(world, `${name}-extensions`);
	cpSync(join(PACKAGE, "extensions"), copy, { recursive: true });
	const wake = join(copy, "lane-mail-wake.ts");
	const source = readFileSync(wake, "utf8");
	const rearm = ": watch(dir, { persistent: false }, () => arm(root, true));";
	if (source.split(rearm).length !== 2) throw new Error(`lane-mail-wake.ts holds the ancestor re-arm ${source.split(rearm).length - 1} times, not once`);
	const mutant = source.replace(rearm, ": watch(dir, { persistent: false }, () => {});");
	if (mutant === source) throw new Error("the ancestor re-arm edit changed nothing");
	writeFileSync(wake, mutant);
	return [join(copy, "hooks.ts"), wake];
}

/** The nearest directory to a lane's mailbox that stands when its session starts. */
type Stands = "mailbox" | "tmp" | "root";

/**
 * - `entries` is what Pi loads: the package from its manifest, the carrier
 *   alone, or both entries from a copy whose watch above a missing mailbox
 *   directory stands but never re-arms, the control for that watch.
 * - `mail` is what the overseer sends and when: after the session is idle, or
 *   during the opening turn's one tool call, which runs on past the append.
 *   The send makes the lane's mailbox directory where it does not stand.
 * - `stands` defaults to the mailbox. `tmp` or `root` is a lane whose mailbox
 *   directory its session started without, which the directive's send makes.
 * - The user scope turns the session-start drift report off: it runs the
 *   machine's own kendex, which is not the subject.
 * - `unsafe` puts a directory where the lane's `to-lane.jsonl` belongs, which
 *   `lane-mail` refuses to read, so the judge fails at every settle.
 * - `prompts` are the turns the case asks for once the mail is sent.
 * - `want.wakes` counts the turns the wake started, each opening with the
 *   judge's keyed `lane-mail-check:` line; `steered` is whether the `Stop`
 *   hook's turn ran, the carrier's own switch and subagent rule standing it
 *   down with the wake.
 */
interface Row {
	name: string;
	entries: "manifest" | "carrier" | "no-ancestor-watch";
	mail: "directive" | "answer" | "busy-directive" | "none";
	stands?: Stands;
	unsafe?: true;
	enabled?: false;
	subagent?: true;
	prompts?: string[];
	want: { wakes: number; state: "directive-read" | "directive-unread" | undefined; steered: boolean };
}

const rows: Row[] = [
	{ name: "a directive, the package loaded from its manifest", entries: "manifest", mail: "directive", want: { wakes: 1, state: "directive-read", steered: true } },
	{ name: "a directive, the carrier alone with no mailbox wake", entries: "carrier", mail: "directive", want: { wakes: 0, state: "directive-unread", steered: true } },
	// An answer belongs to the lane-mail wait that asked for it.
	{ name: "an answer", entries: "manifest", mail: "answer", want: { wakes: 0, state: undefined, steered: true } },
	// A busy lane is handed its mail by the lane-mail-deliver hook after the tool call, and woken for none.
	{ name: "a directive landing while the session is busy", entries: "manifest", mail: "busy-directive", want: { wakes: 0, state: "directive-read", steered: true } },
	{ name: "a directive to a subagent's session", entries: "manifest", mail: "directive", subagent: true, want: { wakes: 0, state: "directive-unread", steered: false } },
	{ name: "a directive with the package switched off", entries: "manifest", mail: "directive", enabled: false, want: { wakes: 0, state: "directive-unread", steered: false } },
	// The judge refuses the missing mailbox at the first settle, one wake; the
	// send that makes the directory wakes the idle session with no prompt.
	{ name: "a directive whose send makes the mailbox, tmp standing", entries: "manifest", mail: "directive", stands: "tmp", want: { wakes: 2, state: "directive-read", steered: true } },
	{ name: "a directive whose send makes the mailbox and tmp", entries: "manifest", mail: "directive", stands: "root", want: { wakes: 2, state: "directive-read", steered: true } },
	{ name: "a directive whose send makes the mailbox, the watch above it never re-arming", entries: "no-ancestor-watch", mail: "directive", stands: "root", want: { wakes: 1, state: "directive-unread", steered: true } },
	{ name: "a mailbox the judge refuses at every settle", entries: "manifest", mail: "none", unsafe: true, prompts: [NEXT, NEXT], want: { wakes: 1, state: undefined, steered: true } },
];

for (const row of rows) {
	test(`mail to a Pi lane: ${row.name}`, async () => {
		const name = row.name.replace(/[^a-z]+/g, "-");
		const { lane, agentDir } = laneWorld(name, row.stands ?? "mailbox", row.enabled !== false);
		if (row.unsafe) mkdirSync(join(lane, "tmp", "lane-mail", ITEM, "to-lane.jsonl"));
		const prompts: string[] = [];
		const saved = { PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR, PI_SUBAGENT_CHILD_AGENT: process.env.PI_SUBAGENT_CHILD_AGENT };
		process.env.PI_CODING_AGENT_DIR = agentDir;
		if (row.subagent) process.env.PI_SUBAGENT_CHILD_AGENT = "reviewer-correctness";
		clearPackageConfigCache();
		const session = await startSession({ cwd: lane, agentDir, paths: entryPaths(row.entries, name), prompts });
		try {
			// The busy row's one tool call appends the directive, then runs
			// on for longer than the judge takes, so a wake that did not wait
			// for the session to be idle would hand the mail over first.
			const opening = row.mail === "busy-directive"
				? `RUN: printf 'Stop after this round.\\n' > ${join(world, "busy.txt")} && ${LANE_MAIL} send --item ${ITEM} --root ${lane} --directive --file ${join(world, "busy.txt")} && sleep 2`
				: WORK;
			await session.prompt(opening);
			await session.waitForIdle();

			let id: string | undefined;
			if (row.mail === "busy-directive") {
				const lines = readFileSync(join(lane, "tmp", "lane-mail", ITEM, "to-lane.jsonl"), "utf8").trim().split("\n");
				id = (JSON.parse(lines.at(-1)!) as { id: string }).id;
			} else if (row.mail !== "none") {
				id = send(lane, row.mail);
			}
			const measure = () => ({
				wakes: prompts.filter((line) => line.startsWith("user: lane-mail-check:")).length,
				state: row.mail === "directive" || row.mail === "busy-directive" ? directiveState(lane, id!) : undefined,
				steered: prompts.some((line) => line.includes("stop-check: handle each")),
			});
			// Real time: the wake is a filesystem event and a spawned judge,
			// and the bound is the interval a live monitor answers within.
			// The judge marks the mail read before the wake's turn starts, so
			// the read alone ends nothing: the wait holds until the turn the
			// row expects has reached the model, or the interval is out. The
			// turn is running once the model saw it, so waitForIdle then
			// waits for it. Only a row that expects a wake to read its mail
			// ends early; any other waits the interval out, since only then is
			// a wake that never came told from a late one, and a row with
			// prompts to come is judged after them.
			const deadline = Date.now() + MAIL_INTERVAL_MS;
			const settled = () =>
				row.prompts === undefined && row.want.wakes > 0 && row.want.state === "directive-read" && Bun.deepEquals(measure(), row.want);
			while (!settled() && Date.now() < deadline) await Bun.sleep(100);
			await session.waitForIdle();
			for (const prompt of row.prompts ?? []) {
				await session.prompt(prompt);
				await session.waitForIdle();
			}
			expect(measure()).toEqual(row.want);
		} finally {
			session.dispose();
			for (const [key, value] of Object.entries(saved)) {
				if (value === undefined) delete process.env[key];
				else process.env[key] = value;
			}
			clearPackageConfigCache();
		}
	}, MAIL_INTERVAL_MS * 4);
}

/**
 * The wake runs the judge with no tool fields and no context window, though
 * the session's model names one: the hook judges the overseer's context mark
 * only on a payload naming its window, and a wake run judging it would start
 * a turn at each settle past the mark. The judge here is a stub that logs
 * each payload it is handed; the opening turn runs no tool, so every logged
 * payload is a wake's.
 */
test("the wake hands its judge no tool and no context window", async () => {
	const lane = join(world, "wake-window");
	mkdirSync(join(lane, "tmp", "lane-mail"), { recursive: true });
	runGit(["init", "-q", "-b", "main"], lane);
	runGit(["config", "gc.auto", "0"], lane);
	runGit(["config", "maintenance.auto", "false"], lane);
	runGit(["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base"], lane);
	const log = join(world, "wake-window.log");
	const judge = join(lane, ".pi", "kendex", "hooks", "lane-mail-deliver.sh");
	mkdirSync(join(judge, ".."), { recursive: true });
	writeFileSync(judge, `#!/usr/bin/env bash\ncat >> ${JSON.stringify(log)}\necho >> ${JSON.stringify(log)}\n`);
	chmodSync(judge, 0o755);
	registerRendered(join(lane, ".pi"), "tool_result", undefined, projectCommand(".pi/kendex/hooks/lane-mail-deliver.sh"), 30);
	const agentDir = join(world, "wake-window-agent");
	mkdirSync(agentDir, { recursive: true });
	writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: { enabled: true, sessionDriftCheck: false } } } } }));
	const saved = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = agentDir;
	const session = await startSession({ cwd: lane, agentDir, paths: [PACKAGE], prompts: [] });
	try {
		await session.prompt(NEXT);
		await session.waitForIdle();
		// Real time: the settle check runs the judge after the turn settles.
		const deadline = Date.now() + MAIL_INTERVAL_MS;
		while (!existsSync(log) && Date.now() < deadline) await Bun.sleep(100);
		const payloads = readFileSync(log, "utf8").trim().split("\n").map((line) => JSON.parse(line) as Record<string, unknown>);
		expect(payloads.length).toBeGreaterThan(0);
		for (const payload of payloads) {
			expect([payload.hook_event_name, payload.tool_name, payload.context_window]).toEqual(["PostToolUse", undefined, undefined]);
		}
	} finally {
		session.dispose();
		if (saved === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = saved;
	}
}, MAIL_INTERVAL_MS * 4);
