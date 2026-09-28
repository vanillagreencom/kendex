import { afterAll, beforeAll, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import { createAgentSession, DefaultResourceLoader, type ExtensionAPI, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";

import { registerRendered, runGit, useIsolatedGitEnv } from "./harness.ts";

/**
 * An overseer's directive reaches an idle Pi lane through the lane's own Pi
 * session, run here in process on the Pi this suite installs: this package
 * loaded from its manifest, a scripted model, and the orch `lane-mail` script
 * doing every read and write. The model answers the wake by running the one
 * command it names, as a lane does, and nothing else.
 *
 * The turn before the directive ends on a `Stop` hook that speaks, the ending
 * the lanes that never woke had in common. Its run is deferred until the
 * settle is over, and a carrier that waited for it inside the settle held the
 * session in that settle for good, so no wake of any kind started a turn.
 */

useIsolatedGitEnv();

const PACKAGE = join(import.meta.dir, "..");
// Spelled whole, so the CI selection that searches for `skills/orch` finds this suite.
const ORCH_SCRIPTS = join(PACKAGE, "../../skills/orch/scripts");
const LANE_MAIL = join(ORCH_SCRIPTS, "lane-mail");
const ITEM = "KEN-7";

/** lane-mail watch's default --interval, the delay a directive to a lane with a live monitor waits at most. */
const MAIL_INTERVAL_MS = 5_000;

let world: string;
beforeAll(() => {
	world = realpathSync(mkdtempSync(join(tmpdir(), "pi-hooks-lane-wake-")));
});
afterAll(() => rmSync(world, { recursive: true, force: true }));

/** A launched lane as `lane-marker` records one, with the orch scripts a kendex install renders. */
function laneWorld(name: string): { lane: string; agentDir: string } {
	const lane = join(world, name);
	mkdirSync(lane, { recursive: true });
	runGit(["init", "-q", "-b", ITEM.toLowerCase()], lane);
	// No background maintenance to race the removal in afterAll.
	runGit(["config", "gc.auto", "0"], lane);
	runGit(["config", "maintenance.auto", "false"], lane);
	runGit(["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base"], lane);
	mkdirSync(join(lane, ".agents", "skills", "orch"), { recursive: true });
	symlinkSync(ORCH_SCRIPTS, join(lane, ".agents", "skills", "orch", "scripts"));
	mkdirSync(join(lane, "tmp", "lane-mail", ITEM), { recursive: true });
	mkdirSync(join(lane, ".git", "lane-mail"), { recursive: true });
	writeFileSync(join(lane, ".git", "lane-mail", ITEM.toLowerCase()), `${lane}\n`);
	const agentDir = join(world, `${name}-agent`);
	mkdirSync(agentDir, { recursive: true });
	// Says its piece once and stands down on the settle it caused, as
	// doc-drift-check does.
	registerRendered(agentDir, "turn_end", undefined, `grep -q '"stop_hook_active":true' && exit 0; echo 'doc-drift: handle each, then finish.' >&2; exit 2`);
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

/** The lane's model: it runs the command a wake names, and ends every other turn at once. */
function scriptedModel(pi: ExtensionAPI, prompts: string[]): void {
	const core = createFauxCore({ api: "lane-wake-faux", provider: "lane-wake-faux", models: [{ id: "lane", contextWindow: 200_000, maxTokens: 1_000 }] });
	const answer = (context: { messages: { role: string; content: unknown }[] }) => {
		const last = context.messages[context.messages.length - 1]!;
		const text = typeof last.content === "string" ? last.content : (last.content as { type: string; text?: string }[]).map((part) => part.text ?? "").join("\n");
		prompts.push(`${last.role}: ${text}`);
		if (last.role === "user" && text.startsWith("lane-mail-wake: mail=")) {
			return fauxAssistantMessage([fauxToolCall("bash", { command: text.split("\n").at(-1)! })], { stopReason: "toolUse" });
		}
		return fauxAssistantMessage([fauxText("done")]);
	};
	core.setResponses(Array.from({ length: 20 }, () => answer));
	pi.registerProvider("lane-wake-faux", {
		api: core.api as never,
		baseUrl: "http://lane-wake.invalid",
		apiKey: "unused",
		streamSimple: core.streamSimple as never,
		models: [{ id: "lane", name: "lane", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200_000, maxTokens: 1_000 }],
	});
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

const rows = [
	{ name: "a directive, the package loaded from its manifest", entries: "manifest", mail: "directive", want: { wakes: 1, state: "directive-read" } },
	{ name: "a directive, the carrier alone with no mailbox wake", entries: "carrier", mail: "directive", want: { wakes: 0, state: "directive-unread" } },
	// An answer belongs to the lane-mail wait that asked for it.
	{ name: "an answer, the package loaded from its manifest", entries: "manifest", mail: "answer", want: { wakes: 0, state: undefined } },
] as const;

for (const row of rows) {
	test(`mail to an idle Pi lane: ${row.name}`, async () => {
		const { lane, agentDir } = laneWorld(`${row.entries}-${row.mail}`);
		const prompts: string[] = [];
		const previous = process.env.PI_CODING_AGENT_DIR;
		process.env.PI_CODING_AGENT_DIR = agentDir;
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
			await session.prompt("Work the item, then wait for your overseer.");
			await session.waitForIdle();
			expect(prompts.some((line) => line.includes("doc-drift: handle each"))).toBe(true);

			const id = send(lane, row.mail);
			// Real time: the wake is a filesystem event and a spawned read,
			// and the bound is the interval a live monitor answers within.
			const deadline = Date.now() + MAIL_INTERVAL_MS;
			while ((row.mail === "answer" || directiveState(lane, id) === "directive-unread") && Date.now() < deadline) await Bun.sleep(100);
			await session.waitForIdle();
			expect({
				wakes: prompts.filter((line) => line.startsWith("user: lane-mail-wake: mail=")).length,
				state: row.mail === "directive" ? directiveState(lane, id) : undefined,
			}).toEqual(row.want);
		} finally {
			session.dispose();
			if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previous;
		}
	}, MAIL_INTERVAL_MS * 4);
}
