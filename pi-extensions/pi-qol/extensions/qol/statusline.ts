import { execFile } from "node:child_process";
import { basename } from "node:path";
import type { ExtensionAPI, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { subagentStatuslineMarker } from "./agent-statusline.js";
import { stripAnsi } from "./ansi.js";
import { readCavemanBridge } from "./bridges.js";
import { glyphs } from "./glyphs.js";
import { CAVEMAN_ICON_ACTIVE, CAVEMAN_ICON_INACTIVE } from "./constants.js";
import { settingBoolean, settingNumber } from "./settings.js";

export interface GitState {
	projectName: string;
	branch?: string;
	dirty: boolean;
	inLinkedWorktree: boolean;
}

function repoNameFromRemote(remote: string): string | undefined {
	const trimmed = remote.trim().replace(/\.git$/, "");
	const match = trimmed.match(/([^/:]+)$/);
	return match?.[1];
}

function formatModelName(ctx: ExtensionContext): string {
	const model = ctx.model;
	if (!model) return "no model";
	let name = model.name || model.id;
	name = name.replace(/^Claude\s+/i, "");
	name = name.replace(/^claude[-_]/i, "");
	name = name.replace(/[-_](20\d{6}|latest)$/i, "");
	name = name.replace(/^gpt[-_]/i, "GPT ");
	name = name.replace(/[-_]/g, " ");
	name = name.replace(/\bopus\b/i, "Opus");
	name = name.replace(/\bsonnet\b/i, "Sonnet");
	name = name.replace(/\bhaiku\b/i, "Haiku");
	name = name.replace(/\s+/g, " ").trim();
	name = name.replace(/\b(Opus|Sonnet|Haiku) (\d) (\d)\b/, "$1 $2.$3");
	return name;
}

type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
const THINKING_TOKEN: Record<ThinkingLevel, "thinkingOff" | "thinkingMinimal" | "thinkingLow" | "thinkingMedium" | "thinkingHigh" | "thinkingXhigh"> = {
	off: "thinkingOff",
	minimal: "thinkingMinimal",
	low: "thinkingLow",
	medium: "thinkingMedium",
	high: "thinkingHigh",
	xhigh: "thinkingXhigh",
};

function normalizeThinkingLevel(value: string | undefined): ThinkingLevel {
	switch ((value ?? "").toLowerCase()) {
		case "off": return "off";
		case "minimal": return "minimal";
		case "low": return "low";
		case "medium": return "medium";
		case "high": return "high";
		case "xhigh": return "xhigh";
		default: return "off";
	}
}

function formatWindow(tokens: number | undefined): string {
	if (!tokens || tokens <= 0) return "?";
	if (tokens >= 1_000_000) {
		const value = tokens / 1_000_000;
		return `${Number.isInteger(value) ? value.toFixed(0) : value.toFixed(1)}M`;
	}
	if (tokens >= 1_000) {
		const value = tokens / 1_000;
		return `${Number.isInteger(value) ? value.toFixed(0) : value.toFixed(1)}k`;
	}
	return `${tokens}`;
}

function statuslineContextInfo(ctx: ExtensionContext): { label: string; percent: number | null } {
	const usage = ctx.getContextUsage();
	const contextWindow = usage?.contextWindow ?? ctx.model?.contextWindow ?? 0;
	if (typeof usage?.percent !== "number") return { label: formatWindow(contextWindow), percent: null };
	const usedPercent = Math.max(0, Math.min(100, Math.round(usage.percent)));
	return { label: formatWindow(contextWindow), percent: 100 - usedPercent };
}

function gitBadge(state: GitState, showDirtyMarker: boolean): string {
	if (!state.branch) return "";
	const icon = state.inLinkedWorktree || state.branch !== "main" ? `🌳 ${state.branch}` : "🦀";
	return ` (${icon}${state.dirty && showDirtyMarker ? "*" : ""})`;
}

export function makeFallbackGitState(cwd: string): GitState {
	return { projectName: basename(cwd), dirty: false, inLinkedWorktree: false };
}

async function runGit(pi: ExtensionAPI, cwd: string, args: string[]): Promise<string | undefined> {
	try {
		const result = await pi.exec("git", ["-C", cwd, ...args], { timeout: settingNumber("gitRefreshTimeoutMs", 1500, cwd) });
		if (result.code !== 0) return undefined;
		const stdout = result.stdout.trim();
		return stdout.length > 0 ? stdout : undefined;
	} catch {
		return undefined;
	}
}

export async function refreshGitState(pi: ExtensionAPI, ctx: ExtensionContext): Promise<GitState> {
	const cwd = ctx.cwd;
	const topLevel = await runGit(pi, cwd, ["rev-parse", "--show-toplevel"]);
	if (!topLevel) return makeFallbackGitState(cwd);
	const [remote, worktreesRaw, branchRaw, shortHead, diffExit] = await Promise.all([
		runGit(pi, cwd, ["remote", "get-url", "origin"]),
		runGit(pi, cwd, ["worktree", "list", "--porcelain"]),
		runGit(pi, cwd, ["branch", "--show-current"]),
		runGit(pi, cwd, ["rev-parse", "--short", "HEAD"]),
		pi.exec("git", ["-C", cwd, "diff-index", "--quiet", "HEAD", "--"], { timeout: settingNumber("gitRefreshTimeoutMs", 1500, cwd) })
			.then((result) => result.code)
			.catch(() => 0),
	]);
	const firstWorktreeLine = worktreesRaw?.split("\n").find((line) => line.startsWith("worktree "));
	const mainWorktree = firstWorktreeLine?.slice("worktree ".length).trim();
	const inLinkedWorktree = Boolean(mainWorktree && mainWorktree !== topLevel);
	const projectName = repoNameFromRemote(remote ?? "") ?? basename(mainWorktree || topLevel);
	const branch = branchRaw || shortHead;
	return { projectName, branch, dirty: diffExit === 1, inLinkedWorktree };
}

export function normalizedSessionName(pi: ExtensionAPI): string | undefined {
	const name = pi.getSessionName();
	if (!name) return undefined;
	const normalized = stripAnsi(name).replace(/[\x00-\x1f\x7f]/g, " ").replace(/\s+/g, " ").trim();
	return normalized || undefined;
}

export function sessionNameHeader(width: number, pi: ExtensionAPI, theme: Pick<Theme, "fg" | "bg">): string[] {
	const name = normalizedSessionName(pi);
	if (!name || width < 4) return [];
	const prefixPlain = "Session ";
	const prefix = theme.fg("muted", prefixPlain);
	const innerWidth = Math.max(1, width - visibleWidth(prefixPlain) - 2);
	const inner = truncateToWidth(name, innerWidth, glyphs().ellipsis);
	const plain = ` ${inner} `;
	const badge = theme.bg("selectedBg", theme.fg("text", plain));
	return [truncateToWidth(`${prefix}${badge}`, width, "")];
}

export function formatTmuxSessionTitle(sessionName: string): string {
	return `${glyphs().prompt} ${sessionName}`;
}

export function tmuxPaneTarget(): string | undefined {
	return process.env.TMUX && process.env.TMUX_PANE ? process.env.TMUX_PANE : undefined;
}

export function readTmuxPaneTitle(target: string, callback: (title: string | undefined) => void): void {
	execFile("tmux", ["display-message", "-p", "-t", target, "#{pane_title}"], { timeout: 1000 }, (error, stdout) => callback(error ? undefined : stdout.replace(/\r?\n$/, "")));
}

export function readTmuxWindowOption(target: string, option: string, callback: (value: string | undefined) => void): void {
	execFile("tmux", ["show-options", "-wqv", "-t", target, option], { timeout: 1000 }, (error, stdout) => callback(error ? undefined : stdout.replace(/\r?\n$/, "")));
}

export function setTmuxPaneTitle(target: string, title: string): void {
	execFile("tmux", ["select-pane", "-t", target, "-T", title], { timeout: 1000 }, () => undefined);
}

export function setTmuxWindowOption(target: string, option: string, value: string): void {
	execFile("tmux", ["set-option", "-wq", "-t", target, option, value], { timeout: 1000 }, () => undefined);
}

export function readTmuxWindowName(target: string, callback: (name: string | undefined) => void): void {
	execFile("tmux", ["display-message", "-p", "-t", target, "#{window_name}"], { timeout: 1000 }, (error, stdout) => callback(error ? undefined : stdout.replace(/\r?\n$/, "")));
}

export function setTmuxWindowName(target: string, name: string): void {
	execFile("tmux", ["rename-window", "-t", target, name], { timeout: 1000 }, () => undefined);
}

function cavemanIconTone(mode: string, active: boolean): "muted" | "text" | "success" | "thinkingHigh" | "error" {
	if (!active) return "muted";
	switch (mode) {
		case "micro": return "text";
		case "lite": return "success";
		case "full": return "thinkingHigh";
		case "ultra": return "error";
		default: return "muted";
	}
}

export function renderStatusLine(width: number, ctx: ExtensionContext, git: GitState, pi: ExtensionAPI, theme: Pick<Theme, "fg">): string {
	const { label: contextLabel, percent } = statuslineContextInfo(ctx);
	const projectChunk = `${git.projectName}${gitBadge(git, settingBoolean("showDirtyMarker", true, ctx.cwd))} ${formatModelName(ctx)}`;
	const statusSeparator = " / ";
	const thinkingLevel = normalizeThinkingLevel(pi.getThinkingLevel());
	const thinkingChunk = thinkingLevel;
	const contextChunk = ` ${contextLabel}`;
	const cavemanBridge = readCavemanBridge();
	const cavemanVisible = !!cavemanBridge && (cavemanBridge.isStatusBadgeEnabled?.(ctx.cwd) ?? true);
	const caveman = cavemanVisible ? cavemanBridge : undefined;
	const cavemanActive = caveman?.isActive() ?? false;
	const cavemanGlyph = caveman ? (cavemanActive ? CAVEMAN_ICON_ACTIVE : CAVEMAN_ICON_INACTIVE) : "";
	const cavemanTone = cavemanIconTone(caveman?.getMode() ?? "off", cavemanActive);
	const cavemanSegment = caveman ? `${statusSeparator}${cavemanGlyph}` : "";
	const contextSeparator = caveman ? ` ${statusSeparator}` : "";
	const leftPlain = `${projectChunk}${statusSeparator}${thinkingChunk}${cavemanSegment}${contextSeparator}${contextChunk.trimStart()}`;
	const percentPlain = percent === null ? `${glyphs(ctx.cwd).ellipsis}%` : `${percent}%`;
	const subagentMarker = subagentStatuslineMarker(ctx.cwd);
	const rightPlain = subagentMarker ? `${percentPlain} ${subagentMarker.plain}` : percentPlain;
	const percentColor = percent === null ? "muted" : percent <= 15 ? "error" : percent <= 30 ? "warning" : "success";
	const separatorColored = theme.fg("muted", statusSeparator);
	const leftColored = caveman
		? `${theme.fg("accent", projectChunk)}${separatorColored}${theme.fg(THINKING_TOKEN[thinkingLevel], thinkingChunk)}${separatorColored}${theme.fg(cavemanTone, cavemanGlyph)}${theme.fg("muted", contextSeparator)}${theme.fg("accent", contextChunk.trimStart())}`
		: `${theme.fg("accent", projectChunk)}${separatorColored}${theme.fg(THINKING_TOKEN[thinkingLevel], thinkingChunk)}${theme.fg("accent", contextChunk)}`;
	const right = subagentMarker ? `${theme.fg(percentColor, percentPlain)} ${subagentMarker.styled}` : theme.fg(percentColor, percentPlain);
	const minimumGap = 1;
	const gapWidth = Math.max(minimumGap, width - visibleWidth(leftPlain) - visibleWidth(rightPlain) - 2);
	const filled = percent === null ? 0 : Math.round(gapWidth * (percent / 100));
	const empty = Math.max(0, gapWidth - filled);
	const bar = " ".repeat(empty) + theme.fg("warning", glyphs(ctx.cwd).line.repeat(filled));
	return truncateToWidth(`${leftColored} ${bar} ${right}`, width, "");
}
