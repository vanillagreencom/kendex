/**
 * Cross-extension bridge to pi-agents-tmux. Other extensions register an
 * object on `globalThis[Symbol.for("vstack.pi.agents")]` exposing per-pane
 * usage stats; we look it up at render time so flightdeck session rows can
 * surface the same cost/turns/tokens that pi-agents-tmux's dashboard shows.
 *
 * Bridge contract is duck-typed across package boundaries so the two
 * extensions can ship and update independently.
 */

import { spawnSync } from "node:child_process";

export interface AgentsBridgeUsage {
	input: number;
	output: number;
	cost: number;
	turns?: number;
}

export interface AgentsBridgeItem {
	agent?: string;
	paneId?: string;
	status?: string;
	model?: string;
	usage?: AgentsBridgeUsage;
}

interface AgentsBridge {
	getByPaneId(paneId: string): AgentsBridgeItem | undefined;
	list(): AgentsBridgeItem[];
}

const SYMBOL = Symbol.for("vstack.pi.agents");

export function getAgentsBridge(): AgentsBridge | undefined {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const bridge = host[SYMBOL];
	if (!bridge || typeof bridge !== "object") return undefined;
	const candidate = bridge as Partial<AgentsBridge>;
	if (typeof candidate.getByPaneId !== "function") return undefined;
	return candidate as AgentsBridge;
}

/**
 * Resolve tmux pane-target strings (`session:window.pane`) to tmux pane ids
 * (`%N`) via a single `tmux list-panes -a` call. Empty Map on tmux failure.
 *
 * Caching: the result is only useful for joining tracked-session
 * pane_target strings against pi-agents-tmux's stats bridge. Refresh
 * cadence is tied to the caller's cache key (joined string of
 * pane_targets) so a poll tick that sees the same tracked-session set
 * reuses the cached map. A coarse TTL guards against drift when a pane
 * dies / is replaced inside an unchanged session set (perf review
 * finding #2).
 */
let PANE_MAP_CACHE: { map: Map<string, string>; key: string; expires: number } | undefined;
const PANE_MAP_TTL_MS = 5000;

export function buildPaneTargetToIdMap(issueKey: string = ""): Map<string, string> {
	const now = Date.now();
	if (PANE_MAP_CACHE && PANE_MAP_CACHE.key === issueKey && PANE_MAP_CACHE.expires > now) {
		return PANE_MAP_CACHE.map;
	}
	const map = new Map<string, string>();
	if (!process.env.TMUX) {
		PANE_MAP_CACHE = { map, key: issueKey, expires: now + PANE_MAP_TTL_MS };
		return map;
	}
	const result = spawnSync("tmux", ["list-panes", "-a", "-F", "#{session_name}:#{window_name}.#{pane_index}\t#{pane_id}"], {
		encoding: "utf8",
		timeout: 1500,
	});
	if (result.status !== 0) {
		PANE_MAP_CACHE = { map, key: issueKey, expires: now + PANE_MAP_TTL_MS };
		return map;
	}
	for (const line of (result.stdout ?? "").split(/\r?\n/)) {
		const [target, paneId] = line.split("\t");
		if (target && paneId) map.set(target, paneId);
	}
	PANE_MAP_CACHE = { map, key: issueKey, expires: now + PANE_MAP_TTL_MS };
	return map;
}

export function formatUsageCompact(usage: AgentsBridgeUsage | undefined): string | undefined {
	if (!usage) return undefined;
	const parts: string[] = [];
	if (usage.cost) parts.push(`$${usage.cost.toFixed(4)}`);
	if (usage.turns) parts.push(`↻${usage.turns}`);
	if (usage.input) parts.push(`↑${formatTokensShort(usage.input)}`);
	if (usage.output) parts.push(`↓${formatTokensShort(usage.output)}`);
	return parts.length > 0 ? parts.join(" ") : undefined;
}

function formatTokensShort(n: number): string {
	if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
	if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
	return `${n}`;
}
