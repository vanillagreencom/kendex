import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type FSWatcher, statSync, watch } from "node:fs";
import { basename, dirname, join } from "node:path";

import { getBool, projectRoot, projectTrusted, readConfig, recordProjectTrust } from "./config.js";
import { agentLine, personLine, runHook, unreadableLine } from "./dispatch.js";
import { runCommandAsync } from "./process.js";
import { registeredHooks, TOOL_RESULT_LISTENER } from "./registry.js";
import { claudeSessionFields } from "./vocab.js";

/** The file an overseer's `lane-mail send` and a hosted `lane-host put` append to, in each lane's mailbox. */
const TO_LANE = "to-lane.jsonl";

/** The registration whose judge hands a lane its unread mail after a tool call; the wake runs the same judge. */
const DELIVER_HOOK = "lane-mail-deliver";

/**
 * The line this module writes when the mailbox watch cannot stand, for the
 * model to read beside the transcript. The settle check still runs without it.
 */
function watchFailed(dir: string, cause: unknown): string {
	return `lane-mail-wake: watch-failed=${dir}\nMail that lands while this session is idle starts no turn until the session next settles.\n${String(cause)}`;
}

/**
 * Whether a directory stands at `dir`. Nothing there, or a file where a
 * directory above it belongs, is a directory not made yet; any other failure
 * to read it is thrown for the watch to report.
 */
function standing(dir: string): boolean {
	try {
		return statSync(dir).isDirectory();
	} catch (error) {
		const code = (error as NodeJS.ErrnoException).code;
		if (code === "ENOENT" || code === "ENOTDIR") return false;
		throw error;
	}
}

/**
 * The mail delivery judge's context, `additionalContext` in the PostToolUse
 * answer the lane-mail-check hook writes on stdout, or the stdout whole where
 * it is not that answer, so an answer this carrier cannot read is said rather
 * than dropped.
 */
function deliveredContext(stdout: string): string {
	try {
		const context = (JSON.parse(stdout) as { hookSpecificOutput?: { additionalContext?: unknown } }).hookSpecificOutput?.additionalContext;
		if (typeof context === "string") return context;
	} catch {
		// Not the JSON answer; handed over as written below.
	}
	return stdout;
}

/**
 * Starts a turn in an idle session when mail the lane-mail hooks hand it
 * lands, the way an idle Claude Code lane is woken by its `lane-mail watch`
 * monitor: an orch lane's own mail, or, for a lead session that is no lane,
 * its checkout's overseer mailbox where the hook names it.
 *
 * Which mailbox this session reads, and what in it is unread and not an
 * answer, are the lane-mail-check hook's to judge, run through
 * the `lane-mail-deliver` registration kendex renders for Pi, the judge that
 * hands a working lane its mail after each tool call. The wake runs that same
 * judge while the session is idle, with the lead's session fields and no tool
 * fields, since no tool ran, and starts one turn through `pi.sendUserMessage`
 * with what the judge hands over; the judge marks the mail read once it has
 * written it, as after a tool call. Anything else the judge says, a refusal or
 * a judge that did not run, starts the same turn, and a wake whose text equals
 * the last one's is not sent again, so a mailbox the judge keeps refusing, or
 * a halt the lane has not yet read, starts one turn and not one per settle.
 *
 * Two triggers ask for the judgement: a change to any mailbox's `to-lane.jsonl`
 * under the checkout's `tmp/lane-mail`, the overseer's included, and each
 * `agent_settled`. Until that directory stands, the nearest directory above it
 * that does, `tmp` or else the checkout root, is watched instead, and once it
 * appears the mailbox watch replaces it and the mail is judged at once, since the
 * `lane-mail send` that made it may have appended before that watch stood.
 * A busy session is left to the
 * lane-mail hooks at its next tool call and turn end. The package lists this
 * entry after `hooks.ts`, and Pi runs handlers in load order, so the settle
 * check runs once the `Stop` registrations have handed over what they will.
 * The package's `enabled` switch is read at each judgement.
 */
export default function laneMailWake(pi: ExtensionAPI): void {
	let ctxRef: ExtensionContext | undefined;
	let watcher: FSWatcher | undefined;
	let lastWake: string | undefined;

	/** A line for the model, recorded without starting a turn. */
	const record = (content: string) => {
		try {
			pi.sendMessage({ customType: "kendex-lane-mail-wake", content, display: true }, { triggerTurn: false });
		} catch {
			// The session was replaced under this send; its successor re-arms.
		}
	};

	const closeWatch = () => {
		watcher?.close();
		watcher = undefined;
	};

	const judge = async (ctx: ExtensionContext) => {
		if (!ctx.isIdle()) return;
		const project = ctx.cwd ? projectRoot(ctx.cwd) : undefined;
		recordProjectTrust(ctx, project);
		if (!getBool(readConfig(ctx.cwd, project), "enabled")) return;
		const registry = registeredHooks(TOOL_RESULT_LISTENER, undefined, project, projectTrusted(ctx));
		let text: string | undefined;
		if (registry.unreadable !== undefined) {
			text = unreadableLine(TOOL_RESULT_LISTENER, registry.unreadable);
		} else {
			const hook = registry.hooks.find((candidate) => candidate.name === DELIVER_HOOK);
			// No registration is kendex having installed no lane mail delivery here.
			if (hook === undefined) return;
			const outcome = await runHook(hook, JSON.stringify({ hook_event_name: "PostToolUse", ...claudeSessionFields(ctx) }), ctx);
			const result = { hook, outcome };
			const forPerson = personLine(result);
			if (forPerson !== undefined && ctx.hasUI) ctx.ui.notify(forPerson, "info");
			const said = agentLine(result, ctx);
			text = outcome.ran && outcome.exitCode === 0 && said !== undefined ? deliveredContext(said) : said;
		}
		if (text === undefined || text === "") {
			lastWake = undefined;
			return;
		}
		if (text === lastWake) return;
		lastWake = text;
		pi.sendUserMessage(text, { deliverAs: "followUp" });
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
			const ctx = ctxRef;
			if (ctx === undefined) return;
			try {
				await judge(ctx);
			} catch (error) {
				// A replaced session's ctx throws from every getter; nothing is left to tell.
				if (ctxRef === ctx) record(`lane-mail-wake: judge-failed=${String(error)}`);
			}
		});
		return tail;
	};

	/**
	 * Watches the checkout's mailbox directory, or, while it does not stand,
	 * the nearest directory above it that does, whose every change re-arms
	 * here, so the watch moves down once the directory below appears. Presence is read before each watch, since
	 * Node's recursive watch on a missing directory throws nothing and never
	 * fires. `appeared` is an arming the mailbox directory's own appearance
	 * caused, whose mail no watch saw land.
	 */
	const arm = (root: string, appeared: boolean) => {
		closeWatch();
		const boxes = join(root, "tmp", "lane-mail");
		const levels = [boxes, dirname(boxes), root];
		let dir = boxes;
		try {
			const at = levels.findIndex(standing);
			if (at === -1) throw new Error(`no directory stands at ${root}, the checkout root git named`);
			dir = levels[at]!;
			const below = levels[at - 1];
			watcher = below === undefined
				? watch(boxes, { persistent: false, recursive: true }, (_kind, name) => {
					if (name == null || basename(name.toString()) === TO_LANE) void check();
				})
				: watch(dir, { persistent: false }, () => arm(root, true));
			const failed = dir;
			watcher.on("error", (error) => {
				closeWatch();
				record(watchFailed(failed, error));
			});
			// The directory below may have appeared before this watch stood.
			if (below !== undefined && standing(below)) arm(root, true);
			else if (below === undefined && appeared) void check();
		} catch (error) {
			closeWatch();
			record(watchFailed(dir, error));
		}
	};

	pi.on("session_start", async (_event, ctx: ExtensionContext) => {
		closeWatch();
		ctxRef = ctx;
		lastWake = undefined;
		const git = await runCommandAsync("git", ["-C", ctx.cwd, "rev-parse", "--show-toplevel"], ctx.cwd, 10_000);
		// No repository holds no lane; the judge still runs at each settle.
		if (git.exitCode !== 0) return;
		// Mail already waiting is judged at the first settle: a launch and a
		// relaunch both open on a prompt, and a wake sent beside it would race it.
		arm(git.stdout.trim(), false);
	});

	// Awaited, so the session reads idle only once the settle's own
	// judgement is over; a wake it sends Pi runs after the settle.
	pi.on("agent_settled", async () => await check());

	pi.on("session_shutdown", async () => {
		closeWatch();
		ctxRef = undefined;
	});
}
