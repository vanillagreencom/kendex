import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type FSWatcher, lstatSync, readdirSync, readFileSync, statSync, watch } from "node:fs";
import { join } from "node:path";

import { getBool, projectRoot, readConfig, recordProjectTrust } from "./config.js";
import { runCommandAsync } from "./process.js";
import { piSubagentName } from "./vocab.js";

/** The file an overseer's `lane-mail send` and a hosted `lane-host put` append to. */
const TO_LANE = "to-lane.jsonl";

/** The orch mailbox reader, relative to the lane's root, the path its launch brief names. */
const READER = ".agents/skills/orch/scripts/lane-mail";

/** The reader's own lock wait is 30 seconds; a peek past that is a failed read. */
const PEEK_TIMEOUT_MS = 35_000;

/** An orch lane this session is: its root, its work item and its mailbox. */
interface Lane {
	root: string;
	item: string;
	box: string;
}

/** Every line this module writes opens `lane-mail-wake: <key>=<value>`; the text under it is here alone. */
function message(key: string, value: string, detail = ""): string {
	const text: Record<string, string> = {
		mail: "Overseer mail landed in this lane mailbox. Run the command below and act on every directive it prints.",
		"peek-failed": "Mail landed in this lane mailbox and the read that judges it failed. Run the command below and act on every directive it prints.",
		git: "git could not name this directory's repository, and it holds a lane mailbox directory, so no mail wakes this session.",
		"marker-ambiguous": "More than one launch marker binds this worktree, so the lane's item is not decided and no mail wakes this session. Remove the marker that is not this lane's.",
		"marker-unreadable": "A launch marker could not be read, so no mail wakes this session.",
		"mailbox-missing": "A launch marker binds this worktree and its mailbox directory is not there, so no mail wakes this session.",
		"mailbox-ambiguous": "More than one mailbox directory lowercases to this lane's item, so no mail wakes this session.",
		"reader-missing": "This worktree has no orch mailbox reader, so no mail wakes this session.",
		"watch-failed": "The watch on this lane mailbox failed, so no further mail wakes this session.",
	};
	return [`lane-mail-wake: ${key}=${value}`, text[key] ?? "", detail].filter((line) => line !== "").join("\n");
}

class LaneRefusal extends Error {}

/** A directory's entries, `undefined` where it does not exist; any other failure is a refusal under `key`. */
function entriesOf(dir: string, key: string): string[] | undefined {
	try {
		return readdirSync(dir);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
		throw new LaneRefusal(message(key, dir, String(error)));
	}
}

/**
 * The lane whose launch recorded `cwd`'s worktree, `undefined` for a session in
 * no launched lane. `lane-marker` writes the record: the lane's root in
 * `<common git dir>/lane-mail/<item in lower case>`, and the mailbox
 * `<root>/tmp/lane-mail/<item>` beside it. The marker is read, not the
 * branch, so a lane is known by what its launch wrote and nothing else. A
 * record present and unusable throws a `LaneRefusal` naming it.
 */
async function resolveLane(cwd: string): Promise<Lane | undefined> {
	const git = await runCommandAsync("git", ["-C", cwd, "rev-parse", "--show-toplevel", "--path-format=absolute", "--git-common-dir"], cwd, 10_000);
	// No repository is no launch, since a lane always runs in one, unless the
	// directory holds a mailbox: then the lane cannot be named.
	if (git.exitCode !== 0) {
		if (entriesOf(join(cwd, "tmp", "lane-mail"), "git") === undefined) return undefined;
		throw new LaneRefusal(message("git", cwd, git.stderr.trim()));
	}
	const [root, common] = git.stdout.trim().split("\n");
	if (root === undefined || common === undefined) throw new LaneRefusal(message("git", cwd, git.stdout.trim()));
	const names = entriesOf(join(common, "lane-mail"), "marker-unreadable");
	if (names === undefined) return undefined;
	const markers = join(common, "lane-mail");
	const bound: string[] = [];
	for (const name of names) {
		const path = join(markers, name);
		if (!lstatSync(path).isFile()) continue;
		let recorded: string;
		try {
			recorded = readFileSync(path, "utf8").split("\n")[0] ?? "";
		} catch (error) {
			throw new LaneRefusal(message("marker-unreadable", path, String(error)));
		}
		if (recorded === root) bound.push(name);
	}
	if (bound.length === 0) return undefined;
	if (bound.length > 1) throw new LaneRefusal(message("marker-ambiguous", bound.join(",")));
	const itemLower = bound[0]!;
	const boxes = join(root, "tmp", "lane-mail");
	const entries = entriesOf(boxes, "mailbox-missing") ?? [];
	const items = entries.filter((name) => name.toLowerCase() === itemLower && statSync(join(boxes, name)).isDirectory());
	if (items.length === 0) throw new LaneRefusal(message("mailbox-missing", join(boxes, itemLower)));
	if (items.length > 1) throw new LaneRefusal(message("mailbox-ambiguous", items.join(",")));
	try {
		statSync(join(root, READER));
	} catch {
		throw new LaneRefusal(message("reader-missing", join(root, READER)));
	}
	return { root, item: items[0]!, box: join(boxes, items[0]!) };
}

/**
 * Starts a turn in an idle orch lane when its overseer's mail lands, the way an
 * idle Claude Code lane is woken by its `lane-mail watch` monitor. The append to
 * the lane's `to-lane.jsonl` is the wake: the mailbox directory is watched, and
 * while the session is idle the unread mail is judged by the orch reader's own
 * `lane-mail inbox --peek`, which leaves answers to the `lane-mail wait` that
 * asked for them. Envelopes it lists that no earlier wake announced start one
 * turn through `pi.sendUserMessage`, carrying the `lane-mail inbox` command
 * that reads them. A busy session is handed its mail by the lane-mail hooks at
 * its next tool call and turn end; the check at each `agent_settled` catches
 * mail those left unread. The package lists this entry after `hooks.ts`, and Pi
 * runs handlers in load order, so that check reads the mailbox once the `Stop`
 * registrations have handed over what they will. A subagent is never woken:
 * its lead reads the lane's mail.
 */
export default function laneMailWake(pi: ExtensionAPI): void {
	let lane: Lane | undefined;
	let watcher: FSWatcher | undefined;
	let ctxRef: ExtensionContext | undefined;
	const announced = new Set<string>();
	let failureAnnounced = false;

	const warn = (ctx: ExtensionContext, text: string) => {
		try {
			if (ctx.hasUI) ctx.ui.notify(text, "warning");
		} catch {
			// A replaced session's ctx; there is nowhere left to report it.
		}
	};

	const stop = () => {
		watcher?.close();
		watcher = undefined;
		lane = undefined;
		ctxRef = undefined;
	};

	const wake = (text: string) => {
		try {
			pi.sendUserMessage(text, { deliverAs: "followUp" });
		} catch {
			// The session was replaced under this send; its successor re-arms.
		}
	};

	const judge = async (current: Lane, ctx: ExtensionContext) => {
		try {
			if (!ctx.isIdle()) return;
		} catch {
			return;
		}
		const inbox = `${READER} inbox --item ${current.item}`;
		const peek = await runCommandAsync(join(current.root, READER), ["inbox", "--peek", "--item", current.item], current.root, PEEK_TIMEOUT_MS);
		if (peek.exitCode !== 0) {
			if (failureAnnounced) return;
			failureAnnounced = true;
			wake(`${message("peek-failed", peek.timedOut ? "timeout" : String(peek.exitCode), peek.stderr.trim())}\n${inbox}`);
			return;
		}
		failureAnnounced = false;
		// The header line, then one envelope per line.
		const fresh: string[] = [];
		for (const line of peek.stdout.split("\n").slice(1)) {
			if (line.trim() === "") continue;
			const id = (JSON.parse(line) as { id?: unknown }).id;
			if (typeof id !== "string") throw new Error(`lane-mail inbox --peek printed an envelope with no id: ${line}`);
			if (!announced.has(id)) fresh.push(id);
		}
		if (fresh.length === 0) return;
		for (const id of fresh) announced.add(id);
		wake(`${message("mail", `${current.item} new=${fresh.length}`)}\n${inbox}`);
	};

	/**
	 * One judgement at a time. A trigger while one is waiting to start joins
	 * it, and a trigger while one runs queues one more, so mail that lands
	 * mid-read is still judged. The promise settles once the judgement it
	 * joined has.
	 */
	let tail: Promise<void> = Promise.resolve();
	let waiting = false;
	const check = (): Promise<void> => {
		if (waiting) return tail;
		waiting = true;
		tail = tail.then(async () => {
			waiting = false;
			const current = lane;
			const ctx = ctxRef;
			if (current === undefined || ctx === undefined) return;
			try {
				await judge(current, ctx);
			} catch (error) {
				warn(ctx, `lane-mail-wake: judge-failed=${current.item}\n${String(error)}`);
			}
		});
		return tail;
	};

	pi.on("session_start", async (_event, ctx: ExtensionContext) => {
		stop();
		if (piSubagentName() !== undefined) return;
		// The package's master switch stands this down with the hooks.
		const project = ctx.cwd ? projectRoot(ctx.cwd) : undefined;
		recordProjectTrust(ctx, project);
		if (!getBool(readConfig(ctx.cwd, project), "enabled")) return;
		let found: Lane | undefined;
		try {
			found = await resolveLane(ctx.cwd);
		} catch (error) {
			if (!(error instanceof LaneRefusal)) throw error;
			warn(ctx, error.message);
			return;
		}
		if (found === undefined) return;
		lane = found;
		ctxRef = ctx;
		try {
			watcher = watch(found.box, { persistent: false }, (_kind, name) => {
				if (name === null || name === TO_LANE) void check();
			});
		} catch (error) {
			warn(ctx, message("watch-failed", found.box, String(error)));
			stop();
			return;
		}
		watcher.on("error", (error) => {
			warn(ctx, message("watch-failed", found.box, String(error)));
			stop();
		});
		// Mail already waiting is judged at the first settle: a launch and a
		// relaunch both open on a prompt, and a wake sent beside it would race it.
	});

	// Awaited, so the session reads idle only once the settle's own
	// judgement is over; a wake it sends Pi runs after the settle.
	pi.on("agent_settled", async () => await check());

	pi.on("session_shutdown", async () => stop());
}
