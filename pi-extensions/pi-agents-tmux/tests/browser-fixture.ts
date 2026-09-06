// The neutral world the dashboard, Monitor and Agents-tab suites render in:
// a pass-through theme, record and item builders, the settings writers and
// an observer that reads a rendered pane back as `label=value` pairs.
// Nothing here plants a defect; a row that needs one builds it inline.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import type { AgentBrowserUiState, AgentPaneStatus, PaneTaskRecord, SubagentDashboardItem } from "../extensions/subagent/types.js";
import { tempRuntime } from "./single-agent-fixture.js";

export { cleanupTempRuntimes, tempRuntime, writeSettings } from "./single-agent-fixture.js";

export const ABSENT = "ABSENT";

export const theme = {
	bg: (_tone: string, text: string) => text,
	bold: (text: string) => text,
	fg: (_tone: string, text: string) => text,
	inverse: (text: string) => text,
};

export function stripAnsi(text: string): string {
	return text.replace(/\x1b\[[0-9;]*m/g, "");
}

export function writeProjectAgent(cwd: string, name: string, frontmatter: string[] = []): void {
	mkdirSync(join(cwd, ".pi", "agents"), { recursive: true });
	writeFileSync(join(cwd, ".pi", "agents", `${name}.md`), ["---", `name: ${name}`, `description: ${name} agent`, ...frontmatter, "---", ""].join("\n"));
}

// The user-level settings file lives under PI_CODING_AGENT_DIR; a temp dir
// there keeps the real user settings out of every row.
export function withTempPiUserDir<T>(fn: (userDir: string) => T): T {
	const previous = process.env.PI_CODING_AGENT_DIR;
	const userDir = tempRuntime();
	process.env.PI_CODING_AGENT_DIR = userDir;
	try {
		return fn(userDir);
	} finally {
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previous;
	}
}

export function writeUserSettings(userDir: string, config: Record<string, unknown>): void {
	mkdirSync(userDir, { recursive: true });
	writeFileSync(join(userDir, "settings.json"), JSON.stringify({
		kendex: { extensionManager: { config: { "@vanillagreen/pi-agents-tmux": config } } },
	}));
}

export function record(agent: string, taskId: string, createdAt: string, patch: Partial<PaneTaskRecord> = {}): PaneTaskRecord {
	return {
		taskId,
		agent,
		task: `Task for ${agent}`,
		status: "completed",
		createdAt,
		completedAt: createdAt,
		updatedAt: createdAt,
		...patch,
	};
}

export function agent(name: string, pane = false, patch: Partial<AgentConfig> = {}): AgentConfig {
	return { name, pane, description: `${name} agent`, systemPrompt: "", source: "project", filePath: `${name}.md`, ...patch };
}

export function uiState(patch: Partial<AgentBrowserUiState> = {}): AgentBrowserUiState {
	return {
		inspectorScroll: 0,
		pane: "inspector",
		tab: "agents",
		scope: "both",
		selected: 0,
		scroll: 0,
		monitorSelected: 0,
		monitorScroll: 0,
		monitorSubtab: 0,
		...patch,
	};
}

export function livePaneStatus(agentName: string, patch: Partial<NonNullable<AgentPaneStatus["entry"]>> = {}, live = true): AgentPaneStatus {
	return {
		live,
		entry: {
			agent: agentName,
			paneId: "%1",
			windowName: `agent-${agentName}`,
			cwd: process.cwd(),
			sessionFile: "/tmp/transcript.jsonl",
			promptFile: "/tmp/prompt.md",
			launcherFile: "/tmp/launcher.sh",
			startedAt: "2026-05-14T05:00:00.000Z",
			...patch,
		},
	};
}

export function dashboardItem(patch: Partial<SubagentDashboardItem> = {}): SubagentDashboardItem {
	return {
		agent: "reviewer-arch",
		kind: "oneshot",
		status: "completed",
		taskId: "reviewer-arch-1700000000-aaaaaaaa",
		updatedAt: "2026-05-14T05:02:00.000Z",
		...patch,
	};
}

// A rendered pane read back as `label` -> `value` for every line shaped
// `Label   value` (two or more spaces), `Label:   value`, or two such
// pairs four or more spaces apart. A label the render does not carry reads
// ABSENT through `fields`, so a row can pin an absence without a regex over
// the whole pane. The first occurrence of a label wins.
export function labelledLines(rendered: string): Map<string, string> {
	const out = new Map<string, string>();
	const set = (label: string, value: string) => {
		if (!out.has(label)) out.set(label, value.trim());
	};
	for (const raw of stripAnsi(rendered).split("\n")) {
		const line = raw.trim();
		const spaced = line.match(/^([A-Za-z][A-Za-z #]*?)\s{2,}(.*)$/);
		if (spaced) {
			set(spaced[1]!, spaced[2]!);
			continue;
		}
		const pairs = line.split(/\s{4,}/).map((part) => part.match(/^([A-Za-z][A-Za-z #]*?): (.*)$/));
		if (pairs.length > 1 && pairs.every(Boolean)) {
			for (const pair of pairs) set(pair![1]!, pair![2]!);
			continue;
		}
		const whole = line.match(/^([A-Za-z][A-Za-z #]*?):\s+(.*)$/);
		if (whole) set(whole[1]!, whole[2]!);
	}
	return out;
}

export function fields(map: Map<string, string>, keys: string[]): Record<string, string> {
	const out: Record<string, string> = {};
	for (const key of keys) out[key] = map.get(key) ?? ABSENT;
	return out;
}
