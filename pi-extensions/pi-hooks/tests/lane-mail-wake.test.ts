import { afterAll, beforeAll, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import { createAgentSession, DefaultResourceLoader, type ExtensionAPI, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";

import { CONFIG_ID, projectCommand, registerRendered, runGit, useIsolatedGitEnv } from "./harness.ts";

/**
 * An overseer's mail reaches a Pi lane through the lane's own Pi session, run
 * here in process on the Pi this package's test script installs: this package
 * loaded from its manifest, a scripted model, orch's `lane-mail` doing every
 * read and write, and the lane-mail hooks kendex renders for Pi, whose judge
 * the wake runs. The model runs a command only where a row's opening prompt
 * names one, and answers everything else at once.
 *
 * The turn before the mail ends on a `Stop` hook that speaks, the ending the
 * lanes that never woke had in common. Its run is deferred until the settle is
 * over, and a carrier that waited for it inside the settle held the session
 * in that settle for good, so no wake of any kind started a turn.
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
 * whose `Stop` hook says its piece once and stands down on the settle it
 * caused, as doc-drift-check does.
 */
function laneWorld(name: string, mailbox: boolean, enabled: boolean): { lane: string; agentDir: string } {
	const lane = join(world, name);
	mkdirSync(lane, { recursive: true });
	runGit(["init", "-q", "-b", ITEM.toLowerCase()], lane);
	// No background maintenance to race the removal in afterAll.
	runGit(["config", "gc.auto", "0"], lane);
	runGit(["config", "maintenance.auto", "false"], lane);
	runGit(["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base"], lane);
	mkdirSync(join(lane, ".agents", "skills", "orch"), { recursive: true });
	symlinkSync(ORCH_SCRIPTS, join(lane, ".agents", "skills", "orch", "scripts"));
	if (mailbox) mkdirSync(join(lane, "tmp", "lane-mail", ITEM), { recursive: true });
	mkdirSync(join(lane, ".git", "lane-mail"), { recursive: true });
	writeFileSync(join(lane, ".git", "lane-mail", ITEM.toLowerCase()), `${lane}\n`);
	mkdirSync(join(lane, ".pi", "kendex", "hooks"), { recursive: true });
	for (const hook of ["lane-mail-check", "lane-mail-deliver"]) {
		copyFileSync(join(REPO, ".pi", "kendex", "hooks", `${hook}.sh`), join(lane, ".pi", "kendex", "hooks", `${hook}.sh`));
	}
	registerRendered(join(lane, ".pi"), "tool_result", undefined, projectCommand(".pi/kendex/hooks/lane-mail-deliver.sh"), 30);
	const agentDir = join(world, `${name}-agent`);
	mkdirSync(agentDir, { recursive: true });
	registerRendered(agentDir, "turn_end", undefined, `grep -q '"stop_hook_active":true' && exit 0; echo 'doc-drift: handle each, then finish.' >&2; exit 2`);
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

/** The lane's model: it runs the command an opening `RUN: ` prompt names, and ends every other turn at once. */
function scriptedModel(pi: ExtensionAPI, prompts: string[]): void {
	const core = createFauxCore({ api: "lane-wake-faux", provider: "lane-wake-faux", models: [{ id: "lane", contextWindow: 200_000, maxTokens: 1_000 }] });
	const answer = (context: { messages: { role: string; content: unknown }[] }) => {
		const last = context.messages[context.messages.length - 1]!;
		const text = typeof last.content === "string" ? last.content : (last.content as { type: string; text?: string }[]).map((part) => part.text ?? "").join("\n");
		prompts.push(`${last.role}: ${text}`);
		if (last.role === "user" && text.startsWith("RUN: ")) return fauxAssistantMessage([fauxToolCall("bash", { command: text.slice(5) })], { stopReason: "toolUse" });
		return fauxAssistantMessage([fauxText("done")]);
	};
	core.setResponses(Array.from({ length: 30 }, () => answer));
	pi.registerProvider("lane-wake-faux", {
		api: core.api as never,
		baseUrl: "http://lane-wake.invalid",
		apiKey: "unused",
		streamSimple: core.streamSimple as never,
		models: [{ id: "lane", name: "lane", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200_000, maxTokens: 1_000 }],
	});
}

/**
 * - `mail` is what the overseer sends and when: after the session is idle, or
 *   during the opening turn's one tool call, which runs on past the append.
 * - `mailbox: false` is a lane whose mailbox directory is made only after its
 *   session started, so no watch stands and only a settle can judge it.
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
	entries: "manifest" | "carrier";
	mail: "directive" | "answer" | "busy-directive" | "none";
	mailbox?: false;
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
	// The judge refuses the missing mailbox once, the watch never stands, and the settle after the directive hands it over.
	{ name: "a directive to a lane whose mailbox was made after its session started", entries: "manifest", mail: "directive", mailbox: false, prompts: [NEXT], want: { wakes: 2, state: "directive-read", steered: true } },
	{ name: "a mailbox the judge refuses at every settle", entries: "manifest", mail: "none", unsafe: true, prompts: [NEXT, NEXT], want: { wakes: 1, state: undefined, steered: true } },
];

for (const row of rows) {
	test(`mail to a Pi lane: ${row.name}`, async () => {
		const name = row.name.replace(/[^a-z]+/g, "-");
		const { lane, agentDir } = laneWorld(name, row.mailbox !== false, row.enabled !== false);
		if (row.unsafe) mkdirSync(join(lane, "tmp", "lane-mail", ITEM, "to-lane.jsonl"));
		const prompts: string[] = [];
		const saved = { PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR, PI_SUBAGENT_CHILD_AGENT: process.env.PI_SUBAGENT_CHILD_AGENT };
		process.env.PI_CODING_AGENT_DIR = agentDir;
		if (row.subagent) process.env.PI_SUBAGENT_CHILD_AGENT = "reviewer-correctness";
		const paths = row.entries === "manifest" ? [PACKAGE] : [join(PACKAGE, "extensions", "hooks.ts")];
		const resourceLoader = new DefaultResourceLoader({
			cwd: lane,
			agentDir,
			noExtensions: true,
			noSkills: true,
			noPromptTemplates: true,
			noThemes: true,
			noContextFiles: true,
			additionalExtensionPaths: paths,
			extensionFactories: [(pi) => scriptedModel(pi, prompts)],
		});
		await resourceLoader.reload();
		const { session } = await createAgentSession({
			cwd: lane,
			agentDir,
			resourceLoader,
			sessionManager: SessionManager.inMemory(lane),
			settingsManager: SettingsManager.inMemory({ compaction: { enabled: false } }),
			tools: ["bash"],
		});
		try {
			// What every Pi mode does before its first prompt: it emits
			// session_start, where extensions start what they hold open.
			await session.bindExtensions({});
			await session.setModel(session.modelRuntime.getModel("lane-wake-faux", "lane")!);
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
				mkdirSync(join(lane, "tmp", "lane-mail", ITEM), { recursive: true });
				id = send(lane, row.mail);
			}
			// Real time: the wake is a filesystem event and a spawned judge,
			// and the bound is the interval a live monitor answers within.
			const deadline = Date.now() + MAIL_INTERVAL_MS;
			while ((row.mail !== "directive" || directiveState(lane, id!) === "directive-unread") && Date.now() < deadline) await Bun.sleep(100);
			await session.waitForIdle();
			for (const prompt of row.prompts ?? []) {
				await session.prompt(prompt);
				await session.waitForIdle();
			}
			expect({
				wakes: prompts.filter((line) => line.startsWith("user: lane-mail-check:")).length,
				state: row.mail === "directive" || row.mail === "busy-directive" ? directiveState(lane, id!) : undefined,
				steered: prompts.some((line) => line.includes("doc-drift: handle each")),
			}).toEqual(row.want);
		} finally {
			session.dispose();
			for (const [key, value] of Object.entries(saved)) {
				if (value === undefined) delete process.env[key];
				else process.env[key] = value;
			}
		}
	}, MAIL_INTERVAL_MS * 4);
}

/**
 * Pi runs handlers in load order, and the settle check has to read the mailbox
 * after the `Stop` registrations have handed over what they will, or a lane
 * whose turn-end hook already handed it its mail is woken for it again.
 */
test("the mailbox wake loads after the carrier", () => {
	const manifest = JSON.parse(readFileSync(join(PACKAGE, "package.json"), "utf8")) as { pi: { extensions: string[] } };
	expect(manifest.pi.extensions).toEqual(["./extensions/hooks.ts", "./extensions/lane-mail-wake.ts"]);
});
