import type { AssistantMessageEvent, AssistantMessageEventStream } from "@earendil-works/pi-ai";
import { homedir } from "node:os";
import { join } from "node:path";

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
		organizationId?: string;
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
	// credentials and endpoint overrides would silently bypass the profile and
	// create separate billing or route its OAuth token through a gateway.
	const directOverrides = new Set([
		"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
		"ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS", "ANTHROPIC_AWS_API_KEY",
		"ANTHROPIC_FOUNDRY_AUTH_TOKEN", "ANTHROPIC_BEDROCK_BASE_URL",
		"ANTHROPIC_VERTEX_BASE_URL", "ANTHROPIC_FOUNDRY_BASE_URL", "AWS_BEARER_TOKEN_BEDROCK",
	]);
	for (const key of Object.keys(env)) {
		if (directOverrides.has(key) || key.startsWith("CLAUDE_CODE_USE_")) delete env[key];
	}
	const configDir = profile.configDir?.trim();
	if (configDir) env.CLAUDE_CONFIG_DIR = configDir;
	else delete env.CLAUDE_CONFIG_DIR;
	return env;
}

export function managedClaudeConfigDir(
	profile: Pick<ClaudeAccountRoute, "configDir">,
	base: NodeJS.ProcessEnv = process.env,
): string {
	const configured = profile.configDir?.trim();
	if (configured) return configured;
	const home = base.HOME?.trim() || homedir();
	return join(home, ".claude");
}

export function accountSessionScope(
	profile: ClaudeAccountRoute | undefined,
	base: NodeJS.ProcessEnv = process.env,
): { accountProfileId?: string; claudeConfigDir?: string } {
	return profile ? {
		accountProfileId: profile.profileId,
		claudeConfigDir: managedClaudeConfigDir(profile, base),
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
	const details: unknown[] = [value];
	if (value && typeof value === "object") {
		const record = value as Record<string, unknown>;
		details.push(record.name, record.message, record.code, record.status, record.statusCode, record.body, record.error);
	}
	const text = details.map((detail) => {
		if (typeof detail === "string" || typeof detail === "number") return String(detail);
		try { return JSON.stringify(detail ?? ""); } catch { return String(detail); }
	}).join(" ");
	const normalized = text.toLowerCase().replace(/[_-]+/g, " ");
	const structuredStatus = value && typeof value === "object"
		? Number((value as Record<string, unknown>).statusCode ?? (value as Record<string, unknown>).status)
		: Number.NaN;
	if (/\b401\b|authentication (?:failed|error)|oauth org not allowed|oauth token.*expired|token.*expired|unauthorized|invalid token|login required|please run .*login|not logged in/.test(normalized)) return "auth";
	// Extra Usage is controlled by Claude account settings. A request asking for
	// it means the current model allowance was rejected, not that Pi should make
	// a billing-policy decision or globally disable the profile.
	if (/extra usage|overage/.test(normalized)) return "rate-limit";
	if (/billing error|payment|required.*billing|credit balance.*(?:low|insufficient|empty)|insufficient credits/.test(normalized)) return "billing";
	if (/\b429\b|rate limit|usage limit|session limit|weekly limit|monthly limit|limit reached|you(?:'|’)ve hit your .* limit|(?:api|usage|request|token|model|account|subscription) quota|too many requests|resets? (?:at )?\d/.test(normalized)) return "rate-limit";
	if (/overloaded|capacity/.test(normalized)) return "overloaded";
	if (
		(Number.isInteger(structuredStatus) && structuredStatus >= 500 && structuredStatus <= 599) ||
		/server error|internal server|(?:http(?: status)?|status|response|error)\s*5\d\d\b/.test(normalized)
	) return "server";
	if (/network|timeout|timed out|socket|econn|connection closed|fetch failed|unexpected end|\beof\b/.test(normalized)) return "network";
	return undefined;
}
