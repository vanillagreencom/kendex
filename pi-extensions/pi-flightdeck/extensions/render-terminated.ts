// Render fragments specific to the post-termination dashboard view
// (issue #17). Extracted from `flightdeck.ts` so additional completion-
// view work doesn't grow the already-1800+ line monolith further
// (BLOCKER from review round 3 reviewer-structure).
//
// Each helper returns plain `string[]` lines and uses the same Pi Theme
// surface as the rest of `flightdeck.ts`. Pure functions of (snapshot,
// theme, width) so they're trivially unit-testable without standing up
// the TUI scaffolding.

import type { Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

import { daemonHealthChip, divider, framePanel, label, sessionCompleteChip } from "./render.js";
import { issueDomain, sessionLabel } from "./session-ui.js";
import { ageSecondsSince, daemonEverStarted, type FlightdeckSnapshot, formatAge, mergedIssueHistory } from "./state.js";

// Header chip for the dashboard/app. Terminated sessions show a
// green "session complete"; otherwise the normal daemon-health chip.
// `archive-error` doesn't take this path — it renders
// `renderArchiveErrorBanner` alongside the regular daemon chip.
export function headerChipForSnapshot(snapshot: FlightdeckSnapshot, theme: Theme): string {
	if (snapshot.master?.terminated) return sessionCompleteChip(theme);
	return daemonHealthChip(theme, {
		alive: snapshot.daemon.pidAlive,
		everStarted: daemonEverStarted(snapshot),
		heartbeatAgeSec: snapshot.daemon.heartbeatAgeSec,
	});
}

// Overview-tab banner. Renders `✔ session complete · at <ts>` + the
// summary file path (when present) and a divider. The caller composes
// this above a tracked-session list so post-mortem context can be rendered
// by explicit archive/history surfaces.
export function renderTerminatedOverviewBanner(snapshot: FlightdeckSnapshot, theme: Theme, width: number): string[] {
	if (!snapshot.master?.terminated) return [];
	const out: string[] = [];
	const when = snapshot.master.terminated_at ?? "";
	const whenTxt = when ? ` ${theme.fg("dim", `at ${when}`)}` : "";
	out.push(`${sessionCompleteChip(theme)}${whenTxt}`);
	if (snapshot.master.summary_path) {
		out.push(`${label(theme, "summary:")} ${theme.fg("text", snapshot.master.summary_path)}`);
	}
	out.push(divider(width, theme));
	return out;
}

// Conflicts & merges Merge-history panel. Stable record of every
// `state=merged` issue-mode session with PR + short merge_commit, surfaced even
// after the live `merge_queue` drains. Without this, the tab showed
// only the empty queue after terminate and merge history was invisible.
export function renderMergeHistorySection(snapshot: FlightdeckSnapshot, theme: Theme): string[] {
	const merged = mergedIssueHistory(snapshot.master);
	const lines: string[] = [];
	lines.push(`${theme.fg("customMessageLabel", theme.bold("Merge history"))} ${theme.fg("dim", `(${merged.length})`)}`);
	if (merged.length === 0) {
		lines.push(theme.fg("dim", "  (no merges recorded)"));
		return lines;
	}
	for (const session of merged) {
		const domain = issueDomain(session);
		const pr = domain?.pr_number ? ` ${theme.fg("dim", "·")} ${theme.fg("accent", `PR#${domain.pr_number}`)}` : "";
		const rawCommit = typeof domain?.merge_commit === "string" ? domain.merge_commit.trim() : "";
		const commit = rawCommit ? theme.fg("success", rawCommit.slice(0, 7)) : theme.fg("dim", "—");
		const when = ageSecondsSince(session.last_polled_at);
		const whenTxt = when !== undefined ? ` ${theme.fg("dim", `${formatAge(when)} ago`)}` : "";
		lines.push(`  ${theme.fg("success", "✓")} ${theme.bold(theme.fg("text", sessionLabel(session)))}${pr} ${theme.fg("dim", "·")} ${commit}${whenTxt}`);
	}
	return lines;
}

// Renders the `summary:` line standalone for tabs that want it without
// the full Overview banner (e.g. Conflicts & merges shows it under the
// merge history).
export function renderSummaryPathLine(snapshot: FlightdeckSnapshot, theme: Theme): string[] {
	const path = snapshot.master?.summary_path;
	if (!path) return [];
	return [`${label(theme, "summary:")} ${theme.fg("text", path)}`];
}

// Conflicts & merges Merge-history + summary-path block, sandwiched
// between the Merge queue and the Conflict graph. Composed here so the
// surrounding spacing rules stay in one place.
export function renderTerminatedConflictsSection(snapshot: FlightdeckSnapshot, theme: Theme): string[] {
	const out: string[] = [""];
	out.push(...renderMergeHistorySection(snapshot, theme));
	const summary = renderSummaryPathLine(snapshot, theme);
	if (summary.length > 0) {
		out.push("");
		out.push(...summary);
	}
	out.push("");
	return out;
}

// Issue-detail block field rendered when a merged issue carries the
// `merge_commit` captured by `close-issue.md § 3`. Returns `[]` when the
// field is absent so the caller can splat unconditionally.
export function renderIssueMergeCommitLine(mergeCommit: string | null | undefined, theme: Theme): string[] {
	if (typeof mergeCommit !== "string") return [];
	const trimmed = mergeCommit.trim();
	if (!trimmed) return [];
	return [`${label(theme, "merge:")} ${theme.fg("success", trimmed.slice(0, 7))} ${theme.fg("dim", trimmed)}`];
}

// Archive-read-error banner (BLOCK round 3). Rendered when every
// candidate terminated archive failed to parse, so the user sees a
// concrete diagnostic instead of an indistinguishable-from-no-session
// blank state.
export function renderArchiveErrorBanner(snapshot: FlightdeckSnapshot, theme: Theme, width: number): string[] {
	const message = snapshot.masterError;
	if (!message) return [];
	const titleLine = `${theme.fg("error", "▲ FLIGHTDECK ARCHIVE READ ERROR")} ${theme.fg("dim", "·")} ${theme.fg("warning", "completed session state unreadable")}`;
	const pathLine = snapshot.masterStatePath
		? `${label(theme, "path:")} ${theme.fg("text", snapshot.masterStatePath)}`
		: "";
	// Don't ANSI-wrap the message itself — long diagnostic strings need
	// truncateToWidth to avoid pushing chat above the viewport top.
	const detailLine = truncateToWidth(`${label(theme, "error:")} ${theme.fg("warning", message)}`, Math.max(1, width - 4), "…");
	const hint = theme.fg("dim", "The archive was selected but could not be parsed. Older archives (if any) were tried in turn. Inspect the file manually for partial-write corruption or hand-edit damage.");
	const inner: string[] = [titleLine];
	if (pathLine) inner.push(pathLine);
	inner.push(detailLine);
	inner.push("");
	for (const row of wrapPlain(hint, frameInnerWidth(width))) inner.push(row);
	return framePanel(inner, width, theme, "error", " ARCHIVE READ ERROR ");
}

function frameInnerWidth(width: number): number {
	return Math.max(8, width - 4);
}

function wrapPlain(text: string, max: number): string[] {
	if (visibleWidth(text) <= max) return [text];
	// Fall back to a hard truncate — banners are short, no need for
	// proper word-wrap here.
	return [truncateToWidth(text, max, "…")];
}
