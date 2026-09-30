import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { processContent, type TruncationMeta } from "../extensions/output-policy.ts";
import { clearPackageConfigCache, recordProjectTrust } from "../extensions/package-config.ts";

const CONFIG_ID = "@vanillagreen/pi-output-policy";

export function writeConfig(cwd: string, config: Record<string, unknown>): void {
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({
		kendex: { extensionManager: { config: { [CONFIG_ID]: config } } },
	}, null, 2));
	// What pi-extension-manager's settings-changed event does after a write.
	clearPackageConfigCache();
}

export function withConfig(config: Record<string, unknown>, run: (cwd: string) => void): void {
	const dir = mkdtempSync(join(tmpdir(), "pi-output-policy-test-"));
	const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(dir, "agent");
	clearPackageConfigCache();
	try {
		writeConfig(dir, config);
		recordProjectTrust({ cwd: dir, isProjectTrusted: () => true });
		run(dir);
	} finally {
		if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
		clearPackageConfigCache();
		rmSync(dir, { force: true, recursive: true });
	}
}

export async function withConfigAsync(config: Record<string, unknown>, run: (cwd: string) => Promise<void>): Promise<void> {
	const dir = mkdtempSync(join(tmpdir(), "pi-output-policy-test-"));
	const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(dir, "agent");
	clearPackageConfigCache();
	try {
		writeConfig(dir, config);
		recordProjectTrust({ cwd: dir, isProjectTrusted: () => true });
		await run(dir);
	} finally {
		if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
		clearPackageConfigCache();
		rmSync(dir, { force: true, recursive: true });
	}
}

/** Isolate both artifact roots, including the OS temporary-directory fallback. */
export async function withArtifactStorage(storage: "user" | "temporary", run: (cwd: string) => Promise<void>): Promise<void> {
	await withConfigAsync({}, async (cwd) => {
		const previous = ["TMPDIR", "TMP", "TEMP"].map((key) => [key, process.env[key]] as const);
		const temporary = join(cwd, "temporary");
		mkdirSync(temporary);
		for (const [key] of previous) process.env[key] = temporary;
		try {
			if (storage === "temporary") writeFileSync(process.env.PI_CODING_AGENT_DIR!, "not a directory");
			await run(cwd);
		} finally {
			for (const [key, value] of previous) {
				if (value === undefined) delete process.env[key];
				else process.env[key] = value;
			}
		}
	});
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
		kendexOutputPolicy: TruncationMeta[];
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


/** Polices one text part and returns the text the model would see, every
 * remaining text part joined by newlines. */
export async function processOne(event: Record<string, unknown>, ctx: ExtensionContext, text: string): Promise<{ text: string; meta?: TruncationMeta }> {
	const result = await processContent(event, ctx, [{ type: "text", text }]);
	const texts = result.content.map((part) => (part as { text: string }).text);
	return { meta: result.meta, text: texts.join("\n") };
}
