// The Anthropic login the bridge's child query actually authenticated as,
// published for other extensions to read.
//
// WHY a published surface rather than letting a reader resolve
// CLAUDE_CONFIG_DIR for itself: that directory names the login only when the
// child used one. The bridge also accepts an API key and the Bedrock, Vertex,
// Foundry, Anthropic-AWS and Mantle backends (auth-presence.ts), and it passes
// those environment values straight to the child (query-options.ts). A
// companion account router may additionally hand each request its own profile
// and rotate it while the process environment never changes
// (account-router.ts). Only the SDK's own accountInfo() names the identity a
// request ran under, so the rule for reading it lives here once instead of in
// every consumer.
//
// SECURITY: this module holds one email in memory and never logs it.

import type { AccountInfo } from "@anthropic-ai/claude-agent-sdk";

export const CLAUDE_BILLING_IDENTITY_SYMBOL = Symbol.for("kendex.pi.claude-bridge.billing-identity.v1");

/** Anthropic's own login backend. Every other `apiProvider` value is an
 *  external credential whose payer this bridge cannot name. */
const FIRST_PARTY = "firstParty";

export interface ClaudeBillingIdentityV1 {
	version: 1;
	/** The Anthropic login email of the most recent child query, or undefined
	 *  when that query authenticated with an API key or a third-party backend,
	 *  when no query has run yet, or when the probe failed. A consumer displays
	 *  this and derives nothing further. */
	currentLoginEmail(): string | undefined;
}

interface BillingIdentityStore extends ClaudeBillingIdentityV1 {
	record(info: AccountInfo): void;
	clear(): void;
}

function nonEmpty(value: string | undefined): string | undefined {
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

/** The login email an `accountInfo()` result confirms, or undefined when it
 *  confirms none. An API key is rejected even under the first-party backend:
 *  the key's owner is not the signed-in login, and `apiKeySource` is how the
 *  SDK reports that a key was used. */
export function loginEmailFrom(info: AccountInfo): string | undefined {
	if (info.apiProvider !== FIRST_PARTY) return undefined;
	if (nonEmpty(info.apiKeySource)) return undefined;
	return nonEmpty(info.email);
}

export function makeBillingIdentityStore(): BillingIdentityStore {
	let loginEmail: string | undefined;
	return {
		version: 1,
		currentLoginEmail: () => loginEmail,
		record: (info) => {
			loginEmail = loginEmailFrom(info);
		},
		clear: () => {
			loginEmail = undefined;
		},
	};
}

export const BRIDGE_BILLING_IDENTITY = makeBillingIdentityStore();

/** Record what the SDK reported for the child that just started. Called from
 *  the stream consumer, so a throw here would fail a live turn: the store is
 *  plain assignment and the caller still guards the promise. */
export function recordBillingIdentity(info: AccountInfo): void {
	BRIDGE_BILLING_IDENTITY.record(info);
}

/** Read the published store, or undefined when no bridge is loaded. Never
 *  installs one: a consumer that created its own would answer for a bridge
 *  that is not running. */
export function resolveClaudeBillingIdentity(): ClaudeBillingIdentityV1 | undefined {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const candidate = host[CLAUDE_BILLING_IDENTITY_SYMBOL] as ClaudeBillingIdentityV1 | undefined;
	return candidate?.version === 1 && typeof candidate.currentLoginEmail === "function" ? candidate : undefined;
}
