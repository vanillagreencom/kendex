/**
 * Tests for the published billing-identity surface: which accountInfo()
 * results confirm an Anthropic login, and what the store answers before,
 * during and after a child query. These exercise billing-identity.ts
 * directly — no live pi instance and no SDK child.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
	CLAUDE_BILLING_IDENTITY_SYMBOL,
	loginEmailFrom,
	makeBillingIdentityStore,
	resolveClaudeBillingIdentity,
} from "../src/billing-identity.ts";

const EMAIL = "lane@example.test";

describe("loginEmailFrom", () => {
	it("confirms a login only for a first-party backend with no API key", () => {
		for (const [info, expected] of [
			[{ apiProvider: "firstParty", email: EMAIL }, EMAIL],
			[{ apiProvider: "firstParty", email: `  ${EMAIL}  ` }, EMAIL],
			[{ apiProvider: "firstParty", email: EMAIL, subscriptionType: "max" }, EMAIL],
			// An API key bills its own owner, not the signed-in login, even on
			// the first-party backend.
			[{ apiKeySource: "ANTHROPIC_API_KEY", apiProvider: "firstParty", email: EMAIL }, undefined],
			[{ apiKeySource: "  helper  ", apiProvider: "firstParty", email: EMAIL }, undefined],
			// Third-party backends authenticate with external credentials.
			[{ apiProvider: "bedrock", email: EMAIL }, undefined],
			[{ apiProvider: "vertex", email: EMAIL }, undefined],
			[{ apiProvider: "foundry", email: EMAIL }, undefined],
			[{ apiProvider: "anthropicAws", email: EMAIL }, undefined],
			[{ apiProvider: "anthropicGoogleCloud", email: EMAIL }, undefined],
			[{ apiProvider: "mantle", email: EMAIL }, undefined],
			[{ apiProvider: "gateway", email: EMAIL }, undefined],
			// Nothing to confirm.
			[{ apiProvider: "firstParty" }, undefined],
			[{ apiProvider: "firstParty", email: "   " }, undefined],
			[{ email: EMAIL }, undefined],
			[{}, undefined],
		]) {
			assert.equal(loginEmailFrom(info), expected, JSON.stringify(info));
		}
	});
});

describe("the billing identity store", () => {
	it("answers nothing until a child query reports one", () => {
		const store = makeBillingIdentityStore();
		assert.equal(store.currentLoginEmail(), undefined);
		store.record({ apiProvider: "firstParty", email: EMAIL });
		assert.equal(store.currentLoginEmail(), EMAIL);
	});

	it("replaces a confirmed login when the next child confirms none", () => {
		const store = makeBillingIdentityStore();
		store.record({ apiProvider: "firstParty", email: EMAIL });
		store.record({ apiProvider: "bedrock" });
		assert.equal(store.currentLoginEmail(), undefined);
	});

	it("forgets the login on clear", () => {
		const store = makeBillingIdentityStore();
		store.record({ apiProvider: "firstParty", email: EMAIL });
		store.clear();
		assert.equal(store.currentLoginEmail(), undefined);
	});
});

describe("resolveClaudeBillingIdentity", () => {
	it("accepts only a v1 store that carries the reader, and installs none", () => {
		const host = globalThis;
		const original = host[CLAUDE_BILLING_IDENTITY_SYMBOL];
		try {
			delete host[CLAUDE_BILLING_IDENTITY_SYMBOL];
			assert.equal(resolveClaudeBillingIdentity(), undefined, "absent publisher");
			assert.equal(
				CLAUDE_BILLING_IDENTITY_SYMBOL in host,
				false,
				"resolve must not install a store of its own",
			);
			for (const [value, expected] of [
				[{ currentLoginEmail: () => EMAIL, version: 1 }, true],
				[{ currentLoginEmail: () => EMAIL, version: 2 }, false],
				[{ currentLoginEmail: () => EMAIL }, false],
				[{ version: 1 }, false],
				[{ currentLoginEmail: EMAIL, version: 1 }, false],
				["published", false],
				[undefined, false],
			]) {
				host[CLAUDE_BILLING_IDENTITY_SYMBOL] = value;
				assert.equal(resolveClaudeBillingIdentity() !== undefined, expected, JSON.stringify(value ?? null));
			}
		} finally {
			if (original === undefined) delete host[CLAUDE_BILLING_IDENTITY_SYMBOL];
			else host[CLAUDE_BILLING_IDENTITY_SYMBOL] = original;
		}
	});
});
