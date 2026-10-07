import { afterAll, beforeAll, expect, test } from "bun:test";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { clearPackageConfigCache } from "../extensions/package-config.ts";
import { TOOL_CALL_LISTENER } from "../extensions/registry.ts";
import { CONFIG_ID, globalCommand, mutatedCarrier, projectCommand, registerRendered, useIsolatedGitEnv } from "./harness.ts";
import { startSession } from "./pi-session.ts";

// Real Pi sessions load the carrier and spawn the catalog hooks. The model's
// complete requests prove delivery, not merely a UI notice or a stored entry.
useIsolatedGitEnv();
const PACKAGE = join(import.meta.dir, "..");
const CATALOG = join(PACKAGE, "..", "..", "hooks");
// A hook that reports a gap and allows the call, its context in the
// PreToolUse hookSpecificOutput shape.
const GAP = "context-notice: missing-library=planted";
const NOTICE = `#!/usr/bin/env bash
printf '%s\\n' '${GAP}' >&2
printf '%s\\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"${GAP}"}}'
`;
const REFUSAL = "block-bare-cd: refused=bare-cd";
let world: string;
beforeAll(() => { world = realpathSync(mkdtempSync(join(tmpdir(), "pi-hooks-pre-context-"))); });
afterAll(() => rmSync(world, { recursive: true, force: true }));

interface Mutation { file: string; before: string; after: string }
interface Row {
	name: string;
	scope: "project" | "global";
	ui: boolean;
	gap: boolean;
	guard: "allow" | "refuse";
	mutation?: Mutation;
}

const rows: Row[] = [];
for (const scope of ["project", "global"] as const) {
	for (const ui of [false, true]) {
		for (const guard of ["allow", "refuse"] as const) {
			rows.push({ name: `${scope}-${ui ? "ui" : "headless"}-${guard}`, scope, ui, gap: true, guard });
		}
	}
	rows.push({ name: `${scope}-normal-refusal`, scope, ui: false, gap: false, guard: "refuse" });
}
const controls: Row[] = [
	{
		name: "must-fail-context-delivery", scope: "project", ui: false, gap: true, guard: "allow",
		mutation: {
			file: "hooks.ts",
			before: '(content) => pi.sendMessage({ customType: "kendex-hook", content, display: true }, { triggerTurn: false }),',
			after: '(content) => pi.sendMessage({ customType: "kendex-hook", content: "", display: true }, { triggerTurn: false }),',
		},
	},
	{
		name: "must-fail-context-envelope", scope: "global", ui: false, gap: true, guard: "allow",
		mutation: { file: "dispatch.ts", before: "return specific.additionalContext;", after: "return stdout;" },
	},
	{
		name: "must-fail-later-guard", scope: "project", ui: false, gap: true, guard: "refuse",
		mutation: {
			file: "hooks.ts",
			before: "(result) => (verdict = toolCallVerdict(result, ctx)) !== undefined,",
			after: "(result) => (verdict = toolCallVerdict(result, ctx)) === undefined,",
		},
	},
	{
		name: "must-fail-refusal", scope: "global", ui: false, gap: false, guard: "refuse",
		mutation: {
			file: "hooks.ts",
			before: "if (!outcome.ran || outcome.exitCode !== 0) {",
			after: "if (false && (!outcome.ran || outcome.exitCode !== 0)) {",
		},
	},
];

for (const row of [...rows, ...controls]) {
	test(`PreToolUse on a Pi session: ${row.name}`, async () => {
		const home = join(world, row.name);
		const cwd = join(home, "project");
		const agentDir = join(home, ".pi", "agent");
		const root = row.scope === "global" ? agentDir : join(cwd, ".pi");
		const marker = join(home, "tool-ran");
		mkdirSync(join(root, "kendex", "hooks"), { recursive: true });
		mkdirSync(cwd, { recursive: true });
		mkdirSync(agentDir, { recursive: true });
		writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: { enabled: true, sessionDriftCheck: false, taskCompletedCheck: false } } } } }));
		for (const name of [...(row.gap ? ["context-notice"] : []), "block-bare-cd"]) {
			const path = join(root, "kendex", "hooks", `${name}.sh`);
			writeFileSync(path, name === "context-notice" ? NOTICE : readFileSync(join(CATALOG, `${name}.sh`), "utf8"));
			registerRendered(root, TOOL_CALL_LISTENER, "Bash", row.scope === "global" ? globalCommand(path) : projectCommand(`.pi/kendex/hooks/${name}.sh`));
		}
		const saved = { HOME: process.env.HOME, PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR };
		process.env.HOME = home;
		process.env.PI_CODING_AGENT_DIR = agentDir;
		clearPackageConfigCache();
		const requests: string[][] = [];
		const notices: string[] = [];
		const modes: boolean[] = [];
		const path = row.mutation === undefined ? join(PACKAGE, "extensions", "hooks.ts")
			: mutatedCarrier(world, row.name, row.mutation.file, row.mutation.before, row.mutation.after);
		const session = await startSession({
			cwd, agentDir, paths: [path], prompts: [], requests,
			settingsManager: SettingsManager.inMemory({ compaction: { enabled: false }, defaultProjectTrust: "always" }),
			bindings: row.ui ? { uiContext: { notify: (text: string) => notices.push(text) } as never } : {},
			factories: [(pi) => pi.on("tool_call", (_event, ctx) => { modes.push(ctx.hasUI); })],
		});
		try {
			const command = `${row.guard === "refuse" ? "cd\n" : ""}printf ran > ${JSON.stringify(marker)}`;
			await session.prompt(`RUN: ${command}`);
			const recorded = session.sessionManager.getBranch().flatMap((entry) =>
				entry.type === "custom_message" && entry.customType === "kendex-hook" ? [String(entry.content).split("\n")[0]] : []);
			const results = session.messages.filter((message) => message.role === "toolResult");
			const observed = {
				model: requests.at(-1)?.filter((line) => line.startsWith("user: ") && !line.startsWith("user: RUN: ")).map((line) => line.slice(6).split("\n")[0]),
				recorded,
				notices: notices.map((line) => line.split("\n")[0]),
				ran: existsSync(marker),
				errors: results.map((message) => message.isError),
				refused: results.some((message) => message.content.some((part) => part.type === "text" && part.text.includes(REFUSAL))),
				requests: requests.length,
			};
			const want = {
				model: row.gap ? [GAP] : [], recorded: row.gap ? [GAP] : [], notices: row.gap && row.ui ? [GAP] : [],
				ran: row.guard === "allow", errors: [row.guard === "refuse"], refused: row.guard === "refuse", requests: 2,
			};
			const assertDelivery = () => expect(observed).toEqual(want);
			if (row.mutation === undefined) assertDelivery();
			else expect(assertDelivery).toThrow();
			// A refusing carrier stops later Pi handlers too. Allowed calls
			// establish that the UI binding actually sets ctx.hasUI.
			if (row.mutation === undefined && row.guard === "allow") expect(modes).toEqual([row.ui]);
		} finally {
			session.dispose();
			for (const [key, value] of Object.entries(saved)) {
				if (value === undefined) delete process.env[key];
				else process.env[key] = value;
			}
			clearPackageConfigCache();
		}
	});
}
