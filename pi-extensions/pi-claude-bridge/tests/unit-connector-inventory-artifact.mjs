/**
 * Artifact test: loads the BUILT bundle, not src.
 *
 * Every other unit suite here imports from `../src/*.ts`, which proves the
 * source is correct and proves nothing about what the package actually ships.
 * Those are different objects and they can disagree — `connectorServerNamespace`
 * was tree-shaken out of `bundle/index.js` entirely because index.ts never calls
 * it, so a consumer following the README could not import the function the
 * README named.
 *
 * This suite exists to catch that class: the public programmatic surface must be
 * importable and callable FROM THE SHIPPED ARTIFACT. It fails on a stale bundle,
 * which is the point — a src change without a rebuild should be caught here.
 */
import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const artifactPath = join(here, "..", "bundle", "connector-inventory.js");

let artifact;

before(async () => {
	assert.ok(
		existsSync(artifactPath),
		`bundle/connector-inventory.js missing — run \`npm run build\` before the tests`,
	);
	artifact = await import(`file://${artifactPath}`);
});

// The entry point consuming apps can actually reach. They regenerate their
// vendored package.json with a CLOSED exports map ({".": "./bundle/index.js"}),
// and Node rejects every unlisted subpath AND deep path under such a map
// (ERR_PACKAGE_PATH_NOT_EXPORTED, verified). So the dedicated
// ./connector-inventory entry is unreachable for them and the ROOT bundle is
// the only allowed path — which makes this the load-bearing case, not the
// secondary one.
describe("root bundle re-export (the path a closed exports map allows)", () => {
	let root;

	before(async () => {
		const rootPath = join(here, "..", "bundle", "index.js");
		assert.ok(existsSync(rootPath), "bundle/index.js missing — run `npm run build`");
		root = await import(`file://${rootPath}`);
	});

	it("exposes the connector API from the extension entry point", () => {
		for (const name of ["listAccountConnectors", "resolveClaudeOAuth", "connectorServerNamespace"]) {
			assert.equal(typeof root[name], "function", `${name} is not reachable from bundle/index.js`);
		}
	});

	it("still registers the pi extension as its default export", () => {
		assert.equal(typeof root.default, "function");
	});
});

describe("shipped connector API", () => {
	it("exports the documented programmatic surface", () => {
		for (const name of [
			"listAccountConnectors",
			"resolveClaudeOAuth",
			"connectorServerNamespace",
			"connectorsListUrl",
			"credentialCandidatePaths",
		]) {
			assert.equal(typeof artifact[name], "function", `${name} is not exported from the built artifact`);
		}
	});

	// Regression for the actual defect: this helper is unused by index.ts, so it
	// was dropped from the extension bundle by tree-shaking. A named export in
	// src is not a shipped export.
	it("keeps exports that the extension entry point never calls", () => {
		assert.equal(artifact.connectorServerNamespace("Google Calendar"), "mcp__claude_ai_Google_Calendar__");
	});

	it("is callable end to end against an injected transport", async () => {
		const result = await artifact.listAccountConnectors({
			credentials: { accessToken: "x".repeat(24), organizationUuid: "org" },
			fetchImpl: async () => new Response(JSON.stringify({ results: [{ name: "Slack", installedServerId: "s1" }] }), { status: 200 }),
		});
		assert.equal(result.ok, true);
		assert.equal(result.complete, true);
		assert.deepEqual(result.connectors.map((c) => c.name), ["Slack"]);
	});

	it("still reports failure rather than an empty list", async () => {
		const result = await artifact.listAccountConnectors({
			credentials: { accessToken: "x".repeat(24), organizationUuid: "org" },
			fetchImpl: async () => new Response("nope", { status: 500 }),
		});
		assert.equal(result.ok, false);
		assert.equal(result.connectors, undefined);
		assert.match(result.reason, /HTTP 500/);
	});
});
