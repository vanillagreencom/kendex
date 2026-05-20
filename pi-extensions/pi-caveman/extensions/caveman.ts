import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
	CONFIG_ID,
	bridgeCavemanHookEnabled,
	configurationSource,
	instructions,
	normalizeActiveMode,
	normalizeMode,
	readVstackConfig,
	settingBoolean,
	settingString,
	shouldClarityEscape,
	type ActiveMode,
	type Mode,
} from "./prompt.js";

const INSTALL_SYMBOL = Symbol.for("vstack.pi-caveman.installed");
const BRIDGE_SYMBOL = Symbol.for("vstack.pi.caveman");
const STATE_TYPE = "vstack-caveman:state";
const STATUS_KEY = "caveman";
const SETTINGS_EVENT = "vstack:extension-settings-changed";

function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

function piUserDir(): string {
	return resolve(expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent"));
}

function safeFileName(value: string): string {
	return value.replace(/[^\w.-]+/g, "_");
}

function sessionIdForContext(ctx: ExtensionContext): string {
	const id = ctx.sessionManager.getSessionId();
	if (id && id.trim()) return id;
	const file = ctx.sessionManager.getSessionFile();
	if (file) return file.split(/[\\/]/).pop()?.replace(/\.jsonl$/, "") ?? `ephemeral-${process.pid}`;
	return `ephemeral-${process.pid}`;
}

function sidecarStatePath(ctx: ExtensionContext): string {
	return join(piUserDir(), "vstack", "sessions", safeFileName(sessionIdForContext(ctx)), "pi-caveman", "state.json");
}

interface CavemanBridge {
	isActive(): boolean;
	getMode(): Mode;
	getConfiguredMode(cwd?: string): Mode;
	getLastActiveMode(): ActiveMode;
	hasSessionOverride(): boolean;
	isStatusBadgeEnabled(cwd?: string): boolean;
	cycleMode(cwd?: string): Mode;
	setMode(mode: string, cwd?: string): Mode | undefined;
	subscribe(listener: () => void): () => void;
}

const CYCLE_ORDER: readonly Mode[] = ["off", "lite", "full", "ultra", "micro"];

const SUBCOMMAND_DESCRIPTIONS: Record<string, string> = {
	lite: "Caveman lite — professional, no fluff",
	full: "Caveman full — classic caveman",
	ultra: "Caveman ultra — maximum compression",
	micro: "Caveman micro — prompt-minimized compression",
	toggle: "Toggle caveman mode on/off",
	debug: "Show resolved mode, settings paths, legacy-key conflicts, and the rendered prompt block",
};

function debugReport(state: CavemanState, ctx: ExtensionContext): string {
	const cwd = ctx.cwd;
	const configured = configuredMode(cwd);
	const effective = effectiveMode(state, cwd);
	const src = configurationSource(cwd);
	const bridgeHook = bridgeCavemanHookEnabled(cwd);
	const overrideLine = state.override === null
		? `Override: none (configured mode "${configured}" wins)`
		: `Override: "${state.override}" (session)`;
	const sourceLine = src.source === "default"
		? "Source: default (no `mode` key found in any settings.json)"
		: `Source: ${src.source} (${src.path})`;
	const legacyLine = src.legacyKeys.length > 0
		? `Legacy keys present alongside \`mode\`: ${src.legacyKeys.join(", ")} (harmless but stale; remove via the extension manager)`
		: "Legacy keys: none";
	const bridgeLine = bridgeHook === undefined
		? "Bridge `includeCavemanHook`: not set (defaults apply; if you use claude-bridge, check its config separately)"
		: `Bridge \`includeCavemanHook\`: ${bridgeHook}`;
	const rendered = effective === "off"
		? "(empty — mode is off)"
		: instructions(effective, cwd, false);
	return [
		`Effective mode: ${effective}`,
		overrideLine,
		sourceLine,
		`Settings paths consulted (in order): ${src.userPath}, ${src.projectPath}`,
		legacyLine,
		bridgeLine,
		"",
		"--- Rendered prompt block ---",
		rendered,
	].join("\n");
}

interface CavemanState {
	override: Mode | null;
	lastActiveMode: ActiveMode;
	updatedAt: string;
}

interface PersistedState {
	override?: Mode | null;
	lastActiveMode?: Mode;
	updatedAt?: string;
	mode?: Mode;
	source?: "default" | "session";
}

function configuredMode(cwd?: string): Mode {
	const config = readVstackConfig(cwd);
	const explicit = normalizeMode(typeof config.mode === "string" ? config.mode : undefined);
	if (explicit) return explicit;
	const legacyEnabled = typeof config.enabled === "boolean" ? config.enabled : false;
	if (!legacyEnabled) return "off";
	return normalizeActiveMode(typeof config.defaultMode === "string" ? config.defaultMode : undefined) ?? "full";
}

function effectiveMode(state: CavemanState, cwd?: string): Mode {
	return state.override ?? configuredMode(cwd);
}

function initialState(cwd?: string): CavemanState {
	const configured = configuredMode(cwd);
	return {
		override: null,
		lastActiveMode: configured === "off" ? "full" : configured,
		updatedAt: new Date().toISOString(),
	};
}

function statusLabel(mode: Mode): string | undefined {
	if (mode === "off") return undefined;
	if (mode === "full") return "CAVEMAN";
	return `CAVEMAN:${mode.toUpperCase()}`;
}

function restoreState(ctx: ExtensionContext): CavemanState {
	let state = initialState(ctx.cwd);
	try {
		const file = sidecarStatePath(ctx);
		if (existsSync(file)) {
			const data = JSON.parse(readFileSync(file, "utf8")) as PersistedState;
			const override = data.override === null ? null : typeof data.override === "string" ? normalizeMode(data.override) ?? null : null;
			state = {
				override,
				lastActiveMode: normalizeActiveMode(data.lastActiveMode) ?? (override && override !== "off" ? override : state.lastActiveMode),
				updatedAt: data.updatedAt ?? new Date().toISOString(),
			};
		}
	} catch {
		// Fall back to session entries below.
	}
	for (const entry of ctx.sessionManager.getBranch()) {
		if (entry.type !== "custom" || entry.customType !== STATE_TYPE) continue;
		const data = entry.data as PersistedState | undefined;
		if (!data) continue;
		let override: Mode | null;
		if (data.override === null) {
			override = null;
		} else if (typeof data.override === "string") {
			override = normalizeMode(data.override) ?? null;
		} else if (typeof data.mode === "string") {
			const legacyMode = normalizeMode(data.mode);
			override = data.source === "session" && legacyMode ? legacyMode : null;
		} else {
			override = state.override;
		}
		const lastActiveMode = normalizeActiveMode(data.lastActiveMode)
			?? (override && override !== "off" ? override : state.lastActiveMode);
		state = {
			override,
			lastActiveMode,
			updatedAt: data.updatedAt ?? new Date().toISOString(),
		};
	}
	return state;
}

function hasPersistedState(ctx: ExtensionContext): boolean {
	if (ctx.sessionManager.getBranch().some((entry) => entry.type === "custom" && entry.customType === STATE_TYPE)) return true;
	try {
		return existsSync(sidecarStatePath(ctx));
	} catch {
		return false;
	}
}

function statusText(state: CavemanState, cwd?: string): string {
	const mode = effectiveMode(state, cwd);
	const suffix = state.override === null ? " (default)" : " (session)";
	return mode === "off" ? `Caveman off${suffix}.` : `Caveman ${mode} active${suffix}.`;
}

export default function caveman(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;

	let state: CavemanState = initialState();
	let activeCtx: ExtensionContext | undefined;
	const listeners = new Set<() => void>();
	const notifyListeners = () => {
		for (const listener of [...listeners]) {
			try { listener(); } catch { /* swallow listener errors */ }
		}
	};

	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const applyOverride = (mode: Mode, cwd?: string): Mode | undefined => {
		if (!settingBoolean("sessionOverrideAllowed", true, cwd)) return undefined;
		const lastActiveMode: ActiveMode = mode === "off" ? state.lastActiveMode : mode;
		state = { override: mode, lastActiveMode, updatedAt: new Date().toISOString() };
		persist();
		syncStatus(activeCtx);
		notifyListeners();
		return mode;
	};

	const bridge: CavemanBridge = {
		isActive: () => effectiveMode(state, activeCtx?.cwd) !== "off",
		getMode: () => effectiveMode(state, activeCtx?.cwd),
		getConfiguredMode: (cwd) => configuredMode(cwd ?? activeCtx?.cwd),
		getLastActiveMode: () => state.lastActiveMode,
		hasSessionOverride: () => state.override !== null,
		isStatusBadgeEnabled: (cwd) => settingBoolean("showStatusBadge", true, cwd),
		cycleMode: (cwd) => {
			const current = effectiveMode(state, cwd ?? activeCtx?.cwd);
			const index = CYCLE_ORDER.indexOf(current);
			const next = CYCLE_ORDER[(index + 1) % CYCLE_ORDER.length] ?? "off";
			return applyOverride(next, cwd ?? activeCtx?.cwd) ?? current;
		},
		setMode: (mode, cwd) => {
			const parsed = normalizeMode(mode);
			if (!parsed) return undefined;
			return applyOverride(parsed, cwd ?? activeCtx?.cwd);
		},
		subscribe: (listener) => {
			listeners.add(listener);
			return () => { listeners.delete(listener); };
		},
	};
	host[BRIDGE_SYMBOL] = bridge;

	const lastFingerprintBySession = new Map<string, string>();
	const persist = () => {
		const snapshot: CavemanState = { ...state, updatedAt: new Date().toISOString() };
		if (activeCtx) {
			const sessionKey = sessionIdForContext(activeCtx);
			// Fingerprint excludes updatedAt so identical mode toggles don't append another full snapshot
			// to the JSONL session log (vstack#177).
			const { updatedAt: _ignored, ...rest } = snapshot;
			const fingerprint = JSON.stringify(rest);
			if (lastFingerprintBySession.get(sessionKey) !== fingerprint) {
				pi.appendEntry<CavemanState>(STATE_TYPE, snapshot);
				lastFingerprintBySession.set(sessionKey, fingerprint);
			}
		} else {
			pi.appendEntry<CavemanState>(STATE_TYPE, snapshot);
		}
		if (!activeCtx) return;
		try {
			const file = sidecarStatePath(activeCtx);
			mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
			writeFileSync(file, `${JSON.stringify(snapshot, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
		} catch {
			// Session custom entries remain the primary restore path.
		}
	};
	const syncStatus = (ctx?: ExtensionContext) => {
		const runCtx = ctx ?? activeCtx;
		if (!runCtx?.hasUI) return;
		const mode = effectiveMode(state, runCtx.cwd);
		runCtx.ui.setStatus(STATUS_KEY, settingBoolean("showStatusBadge", true, runCtx.cwd) ? statusLabel(mode) : undefined);
	};

	pi.on("session_start", (_event, ctx) => {
		activeCtx = ctx;
		const hadSessionState = hasPersistedState(ctx);
		state = restoreState(ctx);
		if (!hadSessionState) {
			const configured = configuredMode(ctx.cwd);
			if (configured !== "off") {
				state = { override: configured, lastActiveMode: configured, updatedAt: new Date().toISOString() };
				persist();
			}
		}
		syncStatus(ctx);
		notifyListeners();
		const legacy = configurationSource(ctx.cwd).legacyKeys;
		if (legacy.length > 0 && ctx.hasUI) {
			ctx.ui.notify(`pi-caveman: legacy settings keys detected (${legacy.join(", ")}) alongside \`mode\`. They are ignored; remove them in the extension manager. Run /caveman debug for details.`, "info");
		}
		// Bridge users hit a silent failure mode: caveman mode is active but the
		// claude-bridge `includeCavemanHook` flag defaults to off, so the
		// directive never reaches Claude. Surface this once per session so the
		// user can fix it in the extension manager.
		if (effectiveMode(state, ctx.cwd) !== "off" && ctx.hasUI && bridgeCavemanHookEnabled(ctx.cwd) === false) {
			ctx.ui.notify("pi-caveman: claude-bridge `includeCavemanHook` is off — caveman directives won't reach Claude. Enable it in the pi-claude-bridge settings, or /caveman debug for details.", "warning");
		}
	});
	pi.on("session_tree", (_event, ctx) => {
		activeCtx = ctx;
		state = restoreState(ctx);
		syncStatus(ctx);
		notifyListeners();
	});
	pi.on("session_shutdown", (_event, ctx) => {
		ctx.ui.setStatus(STATUS_KEY, undefined);
		notifyListeners();
	});

	const applySubcommand = async (sub: string, ctx: ExtensionContext) => {
		activeCtx = ctx;
		const arg = sub.trim().toLowerCase();
		if (arg === "status") {
			ctx.ui.notify(statusText(state, ctx.cwd), "info");
			return;
		}
		if (arg === "debug") {
			ctx.ui.notify(debugReport(state, ctx), "info");
			return;
		}
		const current = effectiveMode(state, ctx.cwd);
		let nextOverride: Mode;
		if (!arg || arg === "toggle") {
			nextOverride = current === "off" ? state.lastActiveMode : "off";
		} else {
			const parsed = normalizeMode(arg);
			if (!parsed) {
				ctx.ui.notify("Unknown caveman mode. Try lite, full, ultra, micro, toggle, off, status, or debug.", "warning");
				return;
			}
			nextOverride = parsed;
		}
		if (!settingBoolean("sessionOverrideAllowed", true, ctx.cwd)) {
			ctx.ui.notify("Session override disabled in caveman settings.", "warning");
			return;
		}
		const lastActiveMode: ActiveMode = nextOverride === "off" ? state.lastActiveMode : nextOverride;
		state = { override: nextOverride, lastActiveMode, updatedAt: new Date().toISOString() };
		persist();
		syncStatus(ctx);
		notifyListeners();
		ctx.ui.notify(nextOverride === "off" ? "Caveman off." : `Caveman ${nextOverride} active.`, "info");
	};

	pi.registerCommand("caveman", {
		description: "Token-efficient caveman response mode.",
		handler: async (args, ctx) => applySubcommand(args, ctx),
	});

	for (const sub of ["lite", "full", "ultra", "micro", "toggle", "debug"] as const) {
		pi.registerCommand(`caveman:${sub}`, {
			description: SUBCOMMAND_DESCRIPTIONS[sub],
			handler: async (_args, ctx) => applySubcommand(sub, ctx),
		});
	}

	pi.events.on(SETTINGS_EVENT, (data: unknown) => {
		if (!data || typeof data !== "object") return;
		const event = data as { extensionId?: unknown; key?: unknown };
		if (event.extensionId !== CONFIG_ID) return;
		if (event.key === "mode") {
			const configured = configuredMode(activeCtx?.cwd);
			const lastActiveMode: ActiveMode = configured === "off" ? state.lastActiveMode : configured;
			state = { override: null, lastActiveMode, updatedAt: new Date().toISOString() };
			persist();
		}
		syncStatus(activeCtx);
		notifyListeners();
	});

	pi.on("before_agent_start", (event, ctx) => {
		activeCtx = ctx;
		const mode = effectiveMode(state, ctx.cwd);
		if (mode === "off") {
			syncStatus(ctx);
			return undefined;
		}
		const clarity = settingBoolean("autoClarityEscape", true, ctx.cwd) && shouldClarityEscape(event.prompt ?? "");
		const prompt = instructions(mode, ctx.cwd, clarity);
		if (clarity && !settingBoolean("resumeAfterClarityEscape", true, ctx.cwd)) {
			state = { override: "off", lastActiveMode: state.lastActiveMode, updatedAt: new Date().toISOString() };
			persist();
			notifyListeners();
		}
		syncStatus(ctx);
		return { systemPrompt: `${event.systemPrompt}\n\n${prompt}` };
	});
}
