import type { AssistantMessageEvent, AssistantMessageEventStream } from "@earendil-works/pi-ai";

export const CLAUDE_ACCOUNT_ROUTER_SYMBOL = Symbol.for("vstack.pi.claude-account-router.v1");
export const CLAUDE_BRIDGE_ACCOUNT_HOST_SYMBOL = Symbol.for("vstack.pi.claude-bridge.account-host.v1");

export interface ClaudeAccountRoute {
	profileId: string;
	label: string;
	configDir?: string;
	/** Effective model selected by the companion after model-scoped quota exhaustion. */
	modelId?: string;
	fallbackReason?: "fable-quota";
}

export type ClaudeAccountFailureKind = "auth" | "billing" | "rate-limit" | "overloaded" | "server" | "network";

export interface ClaudeAccountRouterV1 {
	version: 1;
	acquire(input: {
		modelId: string;
		sessionId?: string;
		excludedProfileIds?: string[];
		forceRerank?: boolean;
		reason?: string;
	}): ClaudeAccountRoute;
	recordIdentity(profileId: string, identity: {
		email?: string;
		organization?: string;
		subscriptionType?: string;
		authMethod?: string;
	}): void;
	recordUsage(profileId: string, usage: unknown): void;
	recordRateLimit(profileId: string, info: Record<string, unknown> | undefined, modelId: string): number;
	recordFailure(profileId: string, kind: ClaudeAccountFailureKind, modelId: string): void;
	recordSuccess(profileId: string, sessionId?: string): void;
	current(modelId: string, sessionId?: string): ClaudeAccountRoute | undefined;
}

export interface ClaudeBridgeAccountHostV1 {
	version: 1;
	probeProfile(input: {
		profile: ClaudeAccountRoute;
		cwd: string;
		signal?: AbortSignal;
	}): Promise<{
		identity?: {
			email?: string;
			organization?: string;
			subscriptionType?: string;
			authMethod?: string;
		};
		usage?: unknown;
	}>;
}

export function resolveClaudeAccountRouter(): ClaudeAccountRouterV1 | undefined {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const candidate = host[CLAUDE_ACCOUNT_ROUTER_SYMBOL] as ClaudeAccountRouterV1 | undefined;
	return candidate?.version === 1 ? candidate : undefined;
}

export function subscriberProfileEnv(
	profile: Pick<ClaudeAccountRoute, "configDir">,
	base: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = { ...base };
	// Managed profiles are subscription identities. Inherited API/provider
	// credentials would silently bypass the profile and create separate billing.
	for (const key of [
		"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
		"CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
		"CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_MANTLE",
	]) delete env[key];
	if (profile.configDir) env.CLAUDE_CONFIG_DIR = profile.configDir;
	else delete env.CLAUDE_CONFIG_DIR;
	return env;
}

export function accountSessionScope(profile: ClaudeAccountRoute | undefined): { accountProfileId?: string; claudeConfigDir?: string } {
	return profile ? {
		accountProfileId: profile.profileId,
		...(profile.configDir ? { claudeConfigDir: profile.configDir } : {}),
	} : {};
}

export function commitsVisibleOutput(event: AssistantMessageEvent): boolean {
	if (event.type === "text_delta" || event.type === "thinking_delta" || event.type === "toolcall_delta") {
		return event.delta.length > 0;
	}
	if (event.type === "text_end" || event.type === "thinking_end") return event.content.length > 0;
	return event.type === "toolcall_end";
}

/**
 * Holds protocol setup events until the first visible delta/tool call. A failed
 * account can then be discarded and retried without leaking a duplicate `start`
 * frame into Pi. Terminal success/error commits the buffered frames.
 */
export class RetryEventBuffer {
	private readonly pending: AssistantMessageEvent[] = [];
	private committed = false;
	private ended = false;
	private discarded = false;

	constructor(
		private readonly target: AssistantMessageEventStream,
		private readonly onCommit?: () => void,
	) {}

	push(event: AssistantMessageEvent): void {
		if (this.discarded) return;
		if (this.committed) {
			this.target.push(event);
			return;
		}
		this.pending.push(event);
		if (commitsVisibleOutput(event) || event.type === "done" || event.type === "error") this.commit();
	}

	end(): void {
		if (this.discarded) return;
		this.ended = true;
		if (this.committed) this.target.end();
	}

	commit(): void {
		if (this.discarded || this.committed) return;
		this.committed = true;
		this.onCommit?.();
		for (const event of this.pending) this.target.push(event);
		this.pending.length = 0;
		if (this.ended) this.target.end();
	}

	discard(): void {
		if (this.committed) return;
		this.discarded = true;
		this.pending.length = 0;
	}

	get hasCommittedOutput(): boolean { return this.committed; }
}

export function rateLimitTypeFromInfo(info: Record<string, unknown> | undefined): unknown {
	return info?.rateLimitType ?? info?.rate_limit_type ?? info?.type;
}

export function rateLimitResetFromInfo(info: Record<string, unknown> | undefined): unknown {
	return info?.resetsAt ?? info?.resets_at ?? info?.resetAt ?? info?.reset_at;
}

export function rateLimitResetMs(info: Record<string, unknown> | undefined): number | undefined {
	const value = rateLimitResetFromInfo(info);
	if (typeof value === "number" && Number.isFinite(value)) return value < 1_000_000_000_000 ? value * 1000 : value;
	if (typeof value !== "string" || !value.trim()) return undefined;
	const numeric = Number(value);
	if (Number.isFinite(numeric)) return numeric < 1_000_000_000_000 ? numeric * 1000 : numeric;
	const parsed = Date.parse(value);
	return Number.isFinite(parsed) ? parsed : undefined;
}

export function classifyClaudeFailure(value: unknown): ClaudeAccountFailureKind | undefined {
	const text = typeof value === "string" ? value : value instanceof Error ? value.message : (() => {
		try { return JSON.stringify(value ?? ""); } catch { return String(value); }
	})();
	const normalized = text.toLowerCase().replace(/[_-]+/g, " ");
	if (/authentication failed|oauth org not allowed|unauthorized|invalid token|login required/.test(normalized)) return "auth";
	if (/billing error|payment|required.*billing|extra usage|overage/.test(normalized)) return "billing";
	if (/rate limit|usage limit|session limit|weekly limit|monthly limit|limit reached|you(?:'|’)ve hit your .* limit|quota|too many requests|resets? (?:at )?\d/.test(normalized)) return "rate-limit";
	if (/overloaded|capacity/.test(normalized)) return "overloaded";
	if (/server error|internal server|\b5\d\d\b/.test(normalized)) return "server";
	if (/network|timeout|timed out|socket|econn|connection closed|fetch failed|unexpected end|\beof\b/.test(normalized)) return "network";
	return undefined;
}
