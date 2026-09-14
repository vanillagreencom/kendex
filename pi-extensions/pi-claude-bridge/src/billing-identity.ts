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
// SECURITY: this module holds one email per live request lane in memory and
// never logs it.

import type { AccountInfo } from "@anthropic-ai/claude-agent-sdk";
import { currentRequestLaneId } from "./request-lane.js";

export const CLAUDE_BILLING_IDENTITY_SYMBOL = Symbol.for("kendex.pi.claude-bridge.billing-identity.v1");

/** Anthropic's own login backend. Every other `apiProvider` value is an
 *  external credential whose payer this bridge cannot name. */
const FIRST_PARTY = "firstParty";

export interface ClaudeBillingIdentityV1 {
	version: 1;
	/** The Anthropic login email of the latest child attempt in `sessionId`, or
	 *  undefined when that attempt authenticated with an API key or a
	 *  third-party backend, has not reported yet, or its probe failed. A
	 *  consumer passes the visible Pi session id, displays the result, and
	 *  derives nothing further. */
	currentLoginEmail(sessionId: string | undefined): string | undefined;
}

interface BillingIdentityStore extends ClaudeBillingIdentityV1 {
	beginAttempt(sessionId: string | undefined): (info: AccountInfo) => void;
	deleteLane(sessionId: string | undefined): void;
	clear(): void;
}

interface BillingIdentityLane {
	attempt: symbol;
	loginEmail?: string;
}

const BILLING_IDENTITY_LANES_SYMBOL = Symbol.for("kendex.pi.claude-bridge.billing-identity-lanes.v1");

function sharedBillingIdentityLanes(): Map<string | undefined, BillingIdentityLane> {
	const host = globalThis as Record<symbol, unknown>;
	let lanes = host[BILLING_IDENTITY_LANES_SYMBOL] as Map<string | undefined, BillingIdentityLane> | undefined;
	if (!lanes) {
		lanes = new Map();
		host[BILLING_IDENTITY_LANES_SYMBOL] = lanes;
	}
	return lanes;
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

export function makeBillingIdentityStore(
	lanes: Map<string | undefined, BillingIdentityLane> = new Map(),
): BillingIdentityStore {
	return {
		version: 1,
		currentLoginEmail: (sessionId) => lanes.get(sessionId)?.loginEmail,
		beginAttempt: (sessionId) => {
			const attempt = Symbol("billing-identity-attempt");
			lanes.set(sessionId, { attempt });
			return (info) => {
				const current = lanes.get(sessionId);
				if (current?.attempt !== attempt) return;
				lanes.set(sessionId, { attempt, loginEmail: loginEmailFrom(info) });
			};
		},
		deleteLane: (sessionId) => lanes.delete(sessionId),
		clear: () => lanes.clear(),
	};
}

export const BRIDGE_BILLING_IDENTITY = makeBillingIdentityStore(sharedBillingIdentityLanes());

/** Start the billing probe for the current request lane. Starting clears that
 *  lane, so a rejected probe cannot leave the previous attempt's identity.
 *  The returned recorder ignores an older probe that settles after a newer
 *  attempt in the same lane. */
export function beginBillingIdentityAttempt(): (info: AccountInfo) => void {
	return BRIDGE_BILLING_IDENTITY.beginAttempt(currentRequestLaneId());
}

/** Remove one completed Pi session without changing concurrent sessions. */
export function deleteBillingIdentityLane(sessionId: string | undefined): void {
	BRIDGE_BILLING_IDENTITY.deleteLane(sessionId);
}

/** Read the published store, or undefined when no bridge is loaded. Never
 *  installs one: a consumer that created its own would answer for a bridge
 *  that is not running. */
export function resolveClaudeBillingIdentity(): ClaudeBillingIdentityV1 | undefined {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const candidate = host[CLAUDE_BILLING_IDENTITY_SYMBOL] as ClaudeBillingIdentityV1 | undefined;
	return candidate?.version === 1 && typeof candidate.currentLoginEmail === "function" ? candidate : undefined;
}
