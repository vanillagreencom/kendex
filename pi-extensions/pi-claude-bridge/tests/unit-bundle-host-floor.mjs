/**
 * Artifact test: links the BUILT bundle against a host pi-ai older than the
 * bridge's floor.
 *
 * `bundle/index.js` externalizes `@earendil-works/pi-ai`, so every named import
 * it keeps is resolved by Node against whatever pi-ai the host installed. A
 * named import of an export an older pi-ai does not have fails MODULE LINKING:
 * no bridge code runs, nothing reports a version problem, and the whole
 * extension is gone — provider, hooks and commands with it. That is strictly
 * worse than the degraded session the floor exists to prevent, so the transcript
 * helpers are read off the namespace and `supportsNativeProvider` is what
 * reports the floor.
 *
 * The bundle is copied beside a stub pi-ai so the copy resolves the stub; the
 * package's own node_modules would otherwise win.
 */
import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const bundlePath = join(here, "..", "bundle", "index.js");

// Everything a pre-0.86 pi-ai exported that the bundle still names directly.
// `calculateCost` is a real named import; the rest are read off the namespace.
const STUB_PI_AI = `
export function calculateCost() { return { total: 0 }; }
export function createProvider(input) { return input; }
export function getModels() { return []; }
export function createAssistantMessageEventStream() { return { push() {}, end() {} }; }
`;

function loadAgainstStub() {
	const root = mkdtempSync(join(tmpdir(), "bridge-host-floor-"));
	try {
		const stubDir = join(root, "node_modules", "@earendil-works", "pi-ai");
		mkdirSync(stubDir, { recursive: true });
		writeFileSync(join(stubDir, "package.json"), JSON.stringify({ name: "@earendil-works/pi-ai", version: "0.85.1", type: "module", main: "index.js" }));
		writeFileSync(join(stubDir, "index.js"), STUB_PI_AI);
		copyFileSync(bundlePath, join(root, "bundle.js"));
		writeFileSync(join(root, "probe.mjs"), `
			import { supportsNativeProvider, NATIVE_PROVIDER_UNSUPPORTED_MESSAGE } from "./bundle.js";
			import * as host from "@earendil-works/pi-ai";
			process.stdout.write(JSON.stringify({ supported: supportsNativeProvider(host), message: NATIVE_PROVIDER_UNSUPPORTED_MESSAGE }));
		`);
		// An explicit environment, so the result does not depend on the developer's.
		const stdout = execFileSync(process.execPath, [join(root, "probe.mjs")], {
			encoding: "utf8",
			env: { PATH: process.env.PATH ?? "", HOME: root },
		});
		return JSON.parse(stdout);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}

describe("the shipped bundle against a pre-0.86 host pi-ai", () => {
	before(() => {
		assert.ok(existsSync(bundlePath), "run npm run build first; this suite reads the shipped artifact");
	});

	it("links, and reports the floor instead of taking the extension down", () => {
		const probe = loadAgainstStub();

		assert.equal(probe.supported, false, "the host is refused");
		assert.match(probe.message, /pi >= 0\.86/, "with a message naming the version to upgrade to");
	});
});
