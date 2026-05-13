import type { Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";
import { homedir } from "node:os";

import { formatUsageCompact, type AgentsBridgeItem } from "./agents-bridge.js";
import { harnessChip, label, pad, stateBadge, stateColor, stateGlyph, tagBadge, wrapLine } from "./render.js";
import { ageSecondsSince, formatAge, isIssueSession as stateIsIssueSession, trackedIssueDomain, type TrackedSession, type TrackedState } from "./state.js";

export const TRACKED_STATE_ORDER: TrackedState[] = ["prompting", "ready", "waiting", "submitting", "merge-ready", "complete", "merged", "cancelled", "aborted", "dead"];

export function sessionLabel(session: TrackedSession | undefined): string {
	if (!session) return "session";
	const title = typeof session.title === "string" ? session.title.trim() : "";
	return title || session.id || session.issue || "session";
}

export function issueDomain(session: TrackedSession | undefined) {
	return trackedIssueDomain(session);
}

export function isIssueSession(session: TrackedSession | undefined): boolean {
	return stateIsIssueSession(session);
}

export function sessionKind(session: TrackedSession | undefined): string | undefined {
	if (!session) return undefined;
	if (isIssueSession(session)) return "issue";
	return typeof session.kind === "string" ? session.kind : undefined;
}

export function issueSessionCount(sessions: TrackedSession[]): number {
	return sessions.filter(isIssueSession).length;
}

export function hasIssueSessions(sessions: TrackedSession[]): boolean {
	return issueSessionCount(sessions) > 0;
}

export function sessionSearchText(session: TrackedSession): string {
	const issue = issueDomain(session);
	return [
		session.id,
		session.title,
		session.issue,
		session.kind,
		session.window,
		session.pane_target,
		session.harness,
		session.state,
		session.substate,
		issue?.id,
		issue?.worktree,
		issue?.pr_number ? `PR#${issue.pr_number}` : "",
	].filter(Boolean).join(" ").toLowerCase();
}

export function sessionPaneTargetLabel(session: TrackedSession | undefined): string | undefined {
	if (!session) return undefined;
	if (typeof session.window === "string" && session.window.trim()) return session.window.trim();
	if (typeof session.pane_target === "string" && session.pane_target.trim()) return session.pane_target.trim();
	return undefined;
}

export function kindBadge(theme: Theme, input: TrackedSession | string | undefined | null): string {
	const raw = input && typeof input === "object" ? sessionKind(input) : input;
	const normalized = typeof raw === "string" ? raw.toLowerCase() : "";
	switch (normalized) {
		case "adhoc": return theme.fg("accent", "AH");
		case "issue": return theme.fg("warning", "ISS");
		case "workflow": return theme.fg("success", "WF");
		default: {
			const text = normalized ? normalized.slice(0, 3).toUpperCase() : "?";
			return theme.fg("muted", text);
		}
	}
}

export function formatStateBreakdown(theme: Theme, sessions: TrackedSession[], options: { includeNames?: boolean; separator?: string } = {}): string {
	const counts = new Map<string, number>();
	for (const session of sessions) {
		const state = session.state ?? "?";
		counts.set(state, (counts.get(state) ?? 0) + 1);
	}
	const ordered = [
		...TRACKED_STATE_ORDER.filter((state) => counts.has(state)),
		...Array.from(counts.keys()).filter((state) => !TRACKED_STATE_ORDER.includes(state)).sort(),
	];
	return ordered.map((state) => {
		const count = counts.get(state) ?? 0;
		const name = options.includeNames ? ` ${state}` : "";
		return theme.fg(stateColor(state), `${stateGlyph(state)} ${count}${name}`);
	}).join(options.separator ?? theme.fg("dim", " "));
}

export function formatSessionTotals(theme: Theme, sessions: TrackedSession[], options: { includeIssueCount?: boolean } = {}): string {
	const total = sessions.length;
	const parts = [theme.fg("muted", `${total} session${total === 1 ? "" : "s"}`)];
	const issues = issueSessionCount(sessions);
	if (options.includeIssueCount !== false && issues > 0) parts.push(theme.fg("muted", `${issues} issue${issues === 1 ? "" : "s"}`));
	return parts.join(` ${theme.fg("muted", "·")} `);
}

export function formatOverviewHeader(theme: Theme, width: number, hasStats: boolean, hasPr: boolean): string {
	const pr = hasPr ? ` ${pad(label(theme, "PR"), 8)}` : "";
	const base = `${pad(label(theme, "SESSION"), 22)} ${pad(label(theme, "KIND"), 6)} ${pad(label(theme, "STATE / PROMPT"), 32)} ${pad(label(theme, "HARNESS"), 10)}${pr}`;
	const stats = hasStats ? ` ${pad(label(theme, "COST / TURNS / TOKENS"), 30)}` : "";
	const line = `${base}${stats} ${label(theme, "AGE")}`;
	return truncateToWidth(line, width, "");
}

function selectedSoft(theme: Theme, selected: boolean, text: string): string {
	return theme.fg(selected ? "text" : "dim", text);
}

export function formatOverviewRow(session: TrackedSession, theme: Theme, width: number, stats: string | undefined, hasStats: boolean, hasPr: boolean, selected = false): string {
	const name = pad(theme.fg("text", sessionLabel(session)), 22);
	const kind = pad(kindBadge(theme, session), 6);
	const soft = (text: string): string => selectedSoft(theme, selected, text);
	const stateAndPrompt = session.substate
		? `${stateBadge(theme, session.state)} ${soft("·")} ${tagBadge(theme, session.substate)}`
		: stateBadge(theme, session.state);
	const state = pad(stateAndPrompt, 32);
	const harness = pad(harnessChip(theme, session.harness ?? undefined), 10);
	const domain = issueDomain(session);
	const pr = hasPr ? ` ${pad(domain?.pr_number ? theme.fg("accent", `#${domain.pr_number}`) : soft("—"), 8)}` : "";
	const statsCell = hasStats ? ` ${pad(stats ? soft(stats) : soft("—"), 30)}` : "";
	const age = formatAge(ageSecondsSince(session.last_polled_at));
	return truncateToWidth(`${name} ${kind} ${state} ${harness}${pr}${statsCell} ${soft(age)}`, width, "");
}

export function renderSessionLine(session: TrackedSession, theme: Theme, stats?: AgentsBridgeItem): string {
	const domain = issueDomain(session);
	const state = stateBadge(theme, session.state);
	const harness = harnessChip(theme, session.harness ?? undefined);
	const pr = domain?.pr_number ? ` ${theme.fg("dim", "·")} ${theme.fg("accent", `PR#${domain.pr_number}`)}` : "";
	const sub = session.substate ? ` ${theme.fg("dim", "·")} ${tagBadge(theme, session.substate)}` : "";
	const polled = ageSecondsSince(session.last_polled_at);
	const polledTxt = polled !== undefined ? ` ${theme.fg("dim", `(${formatAge(polled)})`)}` : "";
	const usageText = formatUsageCompact(stats?.usage);
	const usageTxt = usageText ? ` ${theme.fg("dim", "·")} ${theme.fg("dim", usageText)}` : "";
	return `${kindBadge(theme, session)} ${theme.bold(theme.fg("text", sessionLabel(session)))} ${theme.fg("dim", "·")} ${state} ${theme.fg("dim", "·")} ${harness}${pr}${sub}${usageTxt}${polledTxt}`;
}

export function renderSessionDetailLines(session: TrackedSession, theme: Theme, stats?: AgentsBridgeItem): string[] {
	const out: string[] = [];
	if (session.pane_target) out.push(theme.fg("dim", `pane ${session.pane_target}`));
	if (session.launch?.model || session.launch?.effort || session.launch?.cmd) out.push(theme.fg("dim", `run  ${formatLaunchProfile(session)}`));
	const usageText = formatUsageCompact(stats?.usage);
	if (usageText) out.push(theme.fg("dim", `cost ${usageText}`));
	const domain = issueDomain(session);
	if (domain?.worktree) out.push(theme.fg("dim", `wt   ${compactPath(domain.worktree)}`));
	const decisions = session.decisions_log ?? [];
	const last = decisions[decisions.length - 1];
	if (last) {
		out.push(`${theme.fg("dim", "last ")}${tagBadge(theme, last.prompt_tag)} ${theme.fg("dim", "→")} ${theme.fg("text", last.answer)} ${theme.fg("dim", `${formatAge(ageSecondsSince(last.ts))} ago`)}`);
	}
	if (session.unknown_since) {
		const sec = ageSecondsSince(session.unknown_since);
		out.push(theme.fg("warning", `unknown for ${formatAge(sec)}`));
	}
	if (domain && typeof domain.scope_files_actual === "number" && typeof domain.scope_files_declared === "number" && domain.scope_files_declared > 0) {
		const ratio = domain.scope_files_actual / domain.scope_files_declared;
		const txt = `scope ${domain.scope_files_actual}/${domain.scope_files_declared}`;
		out.push(ratio > 2 ? theme.fg("error", `${txt} (>2× — possible creep)`) : theme.fg("dim", txt));
	}
	return out;
}

export function renderSessionDetailBlock(session: TrackedSession, theme: Theme, width: number, stats?: AgentsBridgeItem): string[] {
	const lines: string[] = [];
	lines.push(`${kindBadge(theme, session)} ${theme.fg("customMessageLabel", theme.bold(sessionLabel(session)))} ${theme.fg("dim", "·")} ${stateBadge(theme, session.state)} ${theme.fg("dim", "·")} ${harnessChip(theme, session.harness ?? undefined)}`);
	if (session.pane_target) lines.push(`${label(theme, "pane:")} ${theme.fg("text", session.pane_target)}`);
	if (session.launch?.model || session.launch?.effort || session.launch?.cmd) lines.push(`${label(theme, "run:")}  ${theme.fg("text", formatLaunchProfile(session))}`);
	const domain = issueDomain(session);
	if (domain?.worktree) lines.push(`${label(theme, "wt:")}   ${theme.fg("text", compactPath(domain.worktree))}`);
	if (domain?.pr_number) lines.push(`${label(theme, "PR:")}   ${theme.fg("accent", `#${domain.pr_number}`)}`);
	const mergeCommit = domain?.merge_commit;
	if (mergeCommit) lines.push(`${label(theme, "merge:")} ${theme.fg("success", mergeCommit.slice(0, 7))} ${theme.fg("dim", mergeCommit)}`);
	if (session.substate) lines.push(`${label(theme, "tag:")}  ${tagBadge(theme, session.substate)}`);
	const usageText = formatUsageCompact(stats?.usage);
	if (usageText) {
		const modelSuffix = stats?.model ? ` ${theme.fg("dim", `(${stats.model})`)}` : "";
		lines.push(`${label(theme, "usage:")} ${theme.fg("text", usageText)}${modelSuffix}`);
	}
	if (session.unknown_since) {
		const sec = ageSecondsSince(session.unknown_since);
		lines.push(`${label(theme, "unknown:")} ${theme.fg("warning", formatAge(sec))}`);
	}
	if (domain && typeof domain.scope_files_actual === "number" && typeof domain.scope_files_declared === "number") {
		lines.push(`${label(theme, "scope:")} ${theme.fg("text", `${domain.scope_files_actual} files`)} ${theme.fg("dim", `(declared ${domain.scope_files_declared})`)}`);
	}
	const decisions = session.decisions_log ?? [];
	if (decisions.length > 0) {
		lines.push("");
		lines.push(label(theme, `last decisions (${decisions.length}):`));
		const recent = decisions.slice(-5);
		for (const entry of recent) {
			lines.push(`  ${theme.fg("dim", entry.ts.slice(11, 19))}  ${tagBadge(theme, entry.prompt_tag)} ${theme.fg("dim", "→")} ${theme.fg("text", entry.answer)}`);
		}
	}
	return lines.flatMap((line) => wrapLine(line, width));
}

export function formatLaunchProfile(session: TrackedSession): string {
	const model = typeof session.launch?.model === "string" && session.launch.model.trim() ? session.launch.model.trim() : "default-model";
	const effort = typeof session.launch?.effort === "string" && session.launch.effort.trim() ? session.launch.effort.trim() : "default-effort";
	const cmd = typeof session.launch?.cmd === "string" && session.launch.cmd.trim() ? ` · ${session.launch.cmd.trim()}` : "";
	return `${model} · ${effort}${cmd}`;
}

function compactPath(input: string): string {
	const home = homedir();
	if (input.startsWith(home)) return `~${input.slice(home.length)}`;
	const cwd = process.cwd();
	if (input.startsWith(cwd)) return `.${input.slice(cwd.length)}`;
	return input;
}
