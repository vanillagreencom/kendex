import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { processText } from "../extensions/output-policy.ts";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { recordProjectTrust } from "../extensions/output-policy.ts";

const CONFIG_ID = "@vanillagreen/pi-output-policy";

export function writeConfig(cwd: string, config: Record<string, unknown>): void {
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({
		kendex: { extensionManager: { config: { [CONFIG_ID]: config } } },
	}, null, 2));
}

export function withConfig(config: Record<string, unknown>, run: (cwd: string) => void): void {
	const dir = mkdtempSync(join(tmpdir(), "pi-output-policy-test-"));
	const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(dir, "agent");
	try {
		writeConfig(dir, config);
		recordProjectTrust({ cwd: dir, isProjectTrusted: () => true });
		run(dir);
	} finally {
		if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
		rmSync(dir, { force: true, recursive: true });
	}
}

export async function withConfigAsync(config: Record<string, unknown>, run: (cwd: string) => Promise<void>): Promise<void> {
	const dir = mkdtempSync(join(tmpdir(), "pi-output-policy-test-"));
	const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(dir, "agent");
	try {
		writeConfig(dir, config);
		recordProjectTrust({ cwd: dir, isProjectTrusted: () => true });
		await run(dir);
	} finally {
		if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
		rmSync(dir, { force: true, recursive: true });
	}
}

let testSeq = 0;
export function fakeCtx(cwd: string): ExtensionContext {
	testSeq += 1;
	const sessionId = `test-${testSeq}`;
	return {
		cwd,
		isProjectTrusted: () => true,
		sessionManager: {
			getSessionId: () => sessionId,
			getSessionFile: () => null,
		},
	} as unknown as ExtensionContext;
}

interface FakeResult {
	content: Array<{ type: string; text: string }>;
	details: {
		[key: string]: unknown;
		big: string;
		kendexOutputPolicy: Array<NonNullable<ReturnType<typeof processText>["meta"]>>;
		kendexOutputPolicySanitized: { policyMode: string };
	};
}

type Handler = (event: Record<string, unknown>, ctx: ExtensionContext) => unknown;

export interface FakePi {
	pi: ExtensionAPI;
	fire: (event: string, payload: Record<string, unknown>, ctx: ExtensionContext) => Promise<FakeResult | undefined>;
}

export function createFakePi(): FakePi {
	const handlers = new Map<string, Handler>();
	const pi = {
		on(event: string, handler: Handler) {
			handlers.set(event, handler);
		},
	};
	return {
		pi: pi as unknown as ExtensionAPI,
		fire: async (event, payload, ctx) => {
			const handler = handlers.get(event);
			if (!handler) throw new Error(`missing-handler=${event}`);
			return await handler(payload, ctx) as FakeResult | undefined;
		},
	};
}

