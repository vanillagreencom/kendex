// Pure prompt-rendering logic for pi-caveman. Kept free of pi-coding-agent
// imports so it can be unit-tested without a Pi runtime. Settings reads are
// driven by `cwd` plus the `PI_CODING_AGENT_DIR` env var, exactly as pi-core
// resolves them at runtime.

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

export type Mode = "off" | "lite" | "full" | "ultra" | "micro";
export type ActiveMode = Exclude<Mode, "off">;
export type kendexConfig = Record<string, unknown>;

export const MODE_VALUES: readonly Mode[] = ["off", "lite", "full", "ultra", "micro"];
export const CONFIG_ID = "@vanillagreen/pi-caveman";

export function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

export function projectSettingsPath(cwd: string): string {
	let current = resolve(cwd);
	while (true) {
		const candidate = join(current, ".pi", "settings.json");
		if (existsSync(candidate)) return candidate;
		if (existsSync(join(current, ".pi")) || existsSync(join(current, ".git")) || existsSync(join(current, ".kendex-lock.json"))) return candidate;
		const parent = dirname(current);
		if (parent === current) return join(resolve(cwd), ".pi", "settings.json");
		current = parent;
	}
}

const PROJECT_TRUST_SYMBOL = Symbol.for("kendex.pi.project-trust");

interface ProjectTrustRegistry {
	projectSettings?: Map<string, boolean>;
}

function projectTrustRegistry(): ProjectTrustRegistry {
	const host = globalThis as unknown as Record<PropertyKey, ProjectTrustRegistry | undefined>;
	const existing = host[PROJECT_TRUST_SYMBOL];
	if (existing) return existing;
	const created: ProjectTrustRegistry = {};
	host[PROJECT_TRUST_SYMBOL] = created;
	return created;
}

export function recordProjectTrust(ctx: { cwd?: string; isProjectTrusted?: () => boolean }): void {
	if (!ctx.cwd) return;
	let trusted = true;
	try {
		trusted = ctx.isProjectTrusted?.() === true;
	} catch {
		trusted = false;
	}
	const registry = projectTrustRegistry();
	if (!registry.projectSettings) registry.projectSettings = new Map();
	registry.projectSettings.set(projectSettingsPath(ctx.cwd), trusted);
}

function projectSettingsTrusted(settingsPath: string): boolean {
	return projectTrustRegistry().projectSettings?.get(settingsPath) === true;
}

/** Root-anchored as `crates/core/src/harness/pi.rs::pi_root_is_absolute_for`
 * means it, which `isAbsolute` is not: it calls a driveless `\root` absolute
 * where the renderer does not, putting the two on different roots. Hoisted, so
 * a circular import cannot reach it inside a temporal dead zone. */
function rootAnchored(path: string, windows: boolean): boolean { return windows ? /^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+)/.test(path) : path.startsWith("/"); }

export function piSettingsPaths(cwd = process.cwd()): string[] {
	const override = expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "");
	const userDir = resolve(rootAnchored(override, process.platform === "win32") ? override : expandHome("~/.pi/agent"));
	const user = join(userDir, "settings.json");
	const project = projectSettingsPath(cwd);
	return projectSettingsTrusted(project) ? [user, project] : [user];
}

export function readkendexConfig(cwd?: string): kendexConfig {
	const merged: kendexConfig = {};
	for (const path of piSettingsPaths(cwd)) {
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			const config = parsed?.kendex?.extensionManager?.config?.[CONFIG_ID];
			if (config && typeof config === "object" && !Array.isArray(config)) Object.assign(merged, config);
		} catch {
			// Ignore malformed optional manager config.
		}
	}
	return merged;
}

export function settingBoolean(key: string, fallback: boolean, cwd?: string): boolean {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "boolean" ? value : fallback;
}

export function settingString(key: string, fallback: string, cwd?: string): string {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "string" ? value : fallback;
}

export interface ConfigurationSource {
	source: "user" | "project" | "default";
	path?: string;
	userPath: string;
	projectPath: string;
}

// Walks user → project settings.json files (matching readkendexConfig order)
// and reports which file's `mode` key won the merge. Project wins on tie.
export function configurationSource(cwd?: string): ConfigurationSource {
	const override = expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "");
	const userDir = resolve(rootAnchored(override, process.platform === "win32") ? override : expandHome("~/.pi/agent"));
	const userPath = join(userDir, "settings.json");
	const projectPath = projectSettingsPath(cwd ?? process.cwd());
	const activePaths = new Set(piSettingsPaths(cwd));
	let sourcePath: string | undefined;
	let sourceLabel: "user" | "project" | "default" = "default";
	for (const [label, path] of [["user", userPath], ["project", projectPath]] as const) {
		if (!activePaths.has(path)) continue;
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			const config = parsed?.kendex?.extensionManager?.config?.[CONFIG_ID];
			if (!config || typeof config !== "object" || Array.isArray(config)) continue;
			if (typeof config.mode === "string") {
				sourceLabel = label;
				sourcePath = path;
			}
		} catch {
			// Ignore malformed optional manager config.
		}
	}
	return { source: sourceLabel, path: sourcePath, userPath, projectPath };
}

// Best-effort read of the pi-claude-bridge extension-manager setting that
// controls whether the caveman block is forwarded into Claude's prompt.
// Does not consult bridge's own claude-bridge.json file (a separate channel);
// /caveman debug surfaces this caveat.
export function bridgeCavemanHookEnabled(cwd?: string): boolean | undefined {
	let value: boolean | undefined;
	for (const path of piSettingsPaths(cwd)) {
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			const config = parsed?.kendex?.extensionManager?.config?.["@vanillagreen/pi-claude-bridge"];
			if (config && typeof config === "object" && !Array.isArray(config) && typeof config.includeCavemanHook === "boolean") {
				value = config.includeCavemanHook;
			}
		} catch {
			// Ignore malformed optional manager config.
		}
	}
	return value;
}

export function normalizeMode(input: string | undefined): Mode | undefined {
	const mode = (input ?? "").trim().toLowerCase();
	if (MODE_VALUES.includes(mode as Mode)) return mode as Mode;
	return undefined;
}

export function normalizeActiveMode(input: string | undefined): ActiveMode | undefined {
	const mode = normalizeMode(input);
	return mode && mode !== "off" ? mode : undefined;
}

// Trigger the hard clarity-escape (plain-prose reply for this turn) ONLY for
// explicit irreversible destructive operations the user is about to confirm
// or run. Soft signals (security/clarify/confused/ambiguous) used to live
// here and produced false escapes on routine technical turns; they belong in
// the model's inline judgment, not in a hard prompt swap.
export function shouldClarityEscape(prompt: string): boolean {
	return /(drop\s+table|rm\s+-rf|force[- ]?push|git\s+reset\s+--hard|git\s+push\s+(?:[^\n]*\s)?--force|\bdestructive\b|\birreversible\b)/i.test(prompt);
}

// Compact boundary clause. Each setting toggles one short label; previously
// each was a full sentence ("Do NOT caveman-transform commit messages and PR
// descriptions unless...") which took ~40% of the block. Live testing
// confirmed the short-label form still keeps commit messages, PRs, and
// external writes out of caveman style. Per-setting opt-out preserved.
function boundaryClauses(cwd: string): string[] {
	const items: string[] = [];
	if (settingBoolean("boundaryNormalForCode", true, cwd)) items.push("code");
	if (settingBoolean("boundaryNormalForCommits", true, cwd)) items.push("commits/PRs");
	if (settingBoolean("boundaryNormalForReviews", true, cwd)) items.push("reviews");
	if (settingBoolean("boundaryNormalForExternalWrites", true, cwd)) items.push("external writes (issues, PR comments, chat, email)");
	return items;
}

function boundaryLine(cwd: string): string | undefined {
	const items = boundaryClauses(cwd);
	if (items.length === 0) return undefined;
	return `Normal-English boundaries (NOT caveman): ${items.join(", ")}. Caveman = chat only.`;
}

export function instructions(mode: Mode, cwd: string, clarityEscape: boolean): string {
	if (mode === "off") return "";
	const suffix = settingString("customPromptSuffix", "", cwd).trim();
	const boundary = boundaryLine(cwd);

	// Clarity escape: irreversible destructive op detected. Write plain prose
	// for the whole reply. NO sentinel marker — the old `Caveman resume`
	// literal taught the model to use `Caveman <verb>:` as a labeling pattern
	// and leaked back into normal output ("Caveman ask:", "Caveman question:").
	// Mode resumes automatically next turn via re-injection by
	// before_agent_start.
	if (clarityEscape) {
		return [
			`You MUST respond in caveman ${mode} style normally — but THIS TURN is a safety override: write clear plain English prose for the entire reply, skip caveman style.`,
			"Caveman returns automatically next turn. Emit NO marker line, NO summary, NO label prefix like 'Caveman ___'.",
			boundary && `Boundaries already normal this turn too: ${boundaryClauses(cwd).join("; ")}.`,
			suffix,
			"You MUST keep this reply plain prose only.",
		].filter(Boolean).join("\n");
	}

	// Anti-markdown rule shared by every active mode. Names the forbidden
	// tokens (`**Bold**`, `##`, `###`) inline because generic "no headers"
	// wording loses to Claude's training preference for markdown structure.
	// Bad/Good header pair was dropped after live testing showed the named-
	// tokens rule alone is sufficient — the example was redundant insurance.
	const antiMarkdown = "No markdown headers (no `**Bold**`, no `## Heading`, no `### Sub`). Use inline lead-ins like `Cost:` or em-dashes between thoughts. Code blocks unchanged.";

	// Micro mode targets the FEWEST tokens. Length anchors got stripped after
	// live testing showed models treated them as advisory hints, not budgets.
	// The identity line + 'Keep it short' closer carry it instead.
	if (mode === "micro") {
		return [
			"You MUST respond in caveman micro style for chat replies. You ARE a smart caveman engineer who answers in the FEWEST tokens that stay correct. Terse — fluff die, technical substance stay.",
			"Apply caveman from first token. No warmup (\"Let me\", \"Here's\", \"I'll\", \"Sure\"). No trailing summary.",
			antiMarkdown,
			"Drop articles, filler (just/really/basically/actually/simply), hedges (might/I think/sort of), pleasantries. Fragments OK. Technical terms + code exact. Pattern: [thing] [action] [reason]. [next step].",
			"Bad: \"Sure! Let me help. The reason your component re-renders is likely because you're creating a new object reference each render.\"",
			"Good: \"New object ref each render. Wrap in `useMemo`.\"",
			boundary,
			suffix,
			"Accuracy > terseness. Keep it short.",
		].filter(Boolean).join("\n");
	}

	// Per-mode delta: directive + one mode-specific example. Models follow
	// few-shot anchors far better than abstract rules — the previous version
	// had no example output anywhere in the block.
	const modeDirective: Record<Exclude<Mode, "off" | "micro">, { rule: string; example: string }> = {
		lite: {
			rule: "Lite: complete sentences, professional tone, active voice. Strip filler ('basically', 'essentially', 'just', 'really', 'simply', 'actually'), hedges ('could potentially', 'might possibly', 'I think', 'sort of'), and pleasantries. Drop decorative articles ('parses flags' beats 'parses the flags'); keep grammatical articles ('a Rust CLI'). Each sentence load-bearing.",
			example: "Lite example: \"Your component re-renders because you create a new object reference each render. Wrap it in `useMemo`.\"",
		},
		full: {
			rule: "Full: classic terse caveman. Drop articles where meaning survives. Fragments OK. Short synonyms preferred.",
			example: "Full example: \"New object ref each render. Inline obj prop = new ref = re-render. Wrap in `useMemo`.\"",
		},
		ultra: {
			rule: "Ultra: maximum compression. Abbreviate (DB/auth/config/req/res/fn/impl). Use → for causality. One word when one suffices.",
			example: "Ultra example: \"Inline obj prop → new ref → re-render. `useMemo`.\"",
		},
	};

	// Lite is a distinct register — tight professional prose with COMPLETE
	// sentences — not a softer caveman. Sharing the caveman identity line
	// + "fragments OK" Good example caused live testing to produce caveman-
	// style fragments under lite (bulleted one-word items, `=` shorthand,
	// `→` arrows). Give lite its own identity + its own Good example so the
	// model has a prose anchor instead of a fragment anchor.
	if (mode === "lite") {
		return [
			`You MUST respond in caveman lite style for chat replies. NOTE: 'lite' here means tight professional prose with COMPLETE SENTENCES, NOT compressed caveman shorthand (no 'X = Y', no '→' chains, no one-word lines). You ARE a tight professional engineer who writes complete sentences with all filler removed.`,
			"Apply from first token. No warmup (\"Let me\", \"Here's\", \"I'll\", \"Sure\", \"Now I'm going to\"). No trailing summary or \"Want me to also…\" tails.",
			antiMarkdown,
			"Strip: filler (just/really/basically/actually/simply/essentially), hedges (might/I think/sort of/could potentially), pleasantries.",
			"Keep: complete sentences, grammatical articles ('a Rust CLI'), active voice, technical terms + code + identifiers + file paths + quoted errors exact.",
			`Bad (caveman shorthand, NOT lite): "New object ref each render. Inline obj prop = new ref → re-render. Wrap in useMemo."`,
			`Good: "Your component re-renders because you create a new object reference on every render. React's shallow prop comparison treats that as a new value and re-renders the child. Wrap the object in \`useMemo\` to keep the reference stable."`,
			boundary,
			suffix,
			"Accuracy beats terseness. Start the very next token in complete-sentence prose.",
		].filter(Boolean).join("\n");
	}

	return [
		`You MUST respond in caveman ${mode} style for chat replies. You ARE a smart caveman engineer. Terse — fluff die, technical substance stay.`,
		"Apply caveman from first token. No warmup (\"Let me\", \"Here's\", \"I'll\", \"Sure\", \"Now I'm going to\"). No trailing summary or \"Want me to also…\" tails.",
		antiMarkdown,
		"Drop: articles, filler (just/really/basically/actually/simply), hedges (might/I think/sort of), pleasantries.",
		"Keep exact: technical terms, code, identifiers, file paths, quoted errors.",
		"Pattern: [thing] [action] [reason]. [next step].",
		"Bad: \"Sure! Let me help. The reason your component re-renders is likely because you're creating a new object reference each render.\"",
		"Good: \"New object ref each render. Wrap in `useMemo`.\"",
		modeDirective[mode].rule,
		modeDirective[mode].example,
		// Inline auto-clarity for destructive confirmations the regex didn't
		// catch. Model self-elects plain prose, no sentinel — sentinel removed
		// system-wide to kill the "Caveman <verb>:" labeling leak.
		"Self-clarity: for an irreversible destructive op confirmation (force-push, drop table, rm -rf, hard reset, branch delete), switch that passage to plain prose inline. No marker line.",
		boundary,
		suffix,
		"Accuracy beats terseness. Start the very next token in caveman style.",
	].filter(Boolean).join("\n");
}
