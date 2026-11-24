import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createReadToolDefinition, VERSION } from "@earendil-works/pi-coding-agent";

import { clearPackageConfigCache, recordProjectTrust } from "../tool-renderer/package-config.js";
import { createReadRenderers } from "../tool-renderer/tools.js";

const createdDirs: string[] = [];
const pngData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
const textOnlyModel = { id: "text-only-model", input: ["text"] };
const visionModel = { id: "vision-model", input: ["text", "image"] };
// Pi 1.6.0 is the first release whose `read` records the model in details (coding-agent changelog entry 338).
const piRecordsUnsupportedModel = Bun.semver.satisfies(VERSION, ">=1.6.0");
// Each color token wraps its text, so a row can be checked for a warning-colored part.
const theme = { bold: (text: string) => text, fg: (token: string, text: string) => `<${token}>${text}</${token}>` };

afterEach(() => {
	for (const dir of createdDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
	clearPackageConfigCache();
});

function tempCwd(config: Record<string, unknown> = {}): string {
	const cwd = mkdtempSync(join(tmpdir(), "pi-tool-renderer-read-unsupported-"));
	createdDirs.push(cwd);
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	writeFileSync(
		join(cwd, ".pi", "settings.json"),
		JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-tool-renderer": config } } } }),
	);
	writeFileSync(join(cwd, "image.png"), Buffer.from(pngData, "base64"));
	recordProjectTrust({ cwd, isProjectTrusted: () => true });
	return cwd;
}

function draw(renderers: any, result: any, cwd: string, expanded: boolean): string[] {
	const context = { args: { path: "image.png" }, cwd, invalidate() {}, showImages: false, state: {} };
	return renderers.renderResult(result, { expanded, isPartial: false }, theme, context).render(300);
}

function warnsAbout(lines: string[], model: string): boolean {
	const warnings = lines.join("\n").match(/<warning>[^<]*<\/warning>/g) ?? [];
	return warnings.some((part) => part.includes(model));
}

async function piRead(cwd: string, model: typeof textOnlyModel): Promise<any> {
	return createReadToolDefinition(cwd).execute("read-1", { path: "image.png" }, undefined, undefined, { cwd, model } as any);
}

describe("a read image the model cannot see", () => {
	test.skipIf(!piRecordsUnsupportedModel)("Pi's read result draws the warning in Pi's view and the package's, collapsed and expanded", async () => {
		const cwd = tempCwd();
		const unsupported = await piRead(cwd, textOnlyModel);
		const supported = await piRead(cwd, visionModel);
		expect(unsupported.details?.imageUnsupportedByModel).toBe(textOnlyModel.id);
		expect(supported.details?.imageUnsupportedByModel).toBeUndefined();

		const pi = createReadToolDefinition(cwd);
		const pkg = createReadRenderers(cwd);
		for (const expanded of [false, true]) {
			expect({ view: "pi", expanded, warns: warnsAbout(draw(pi, unsupported, cwd, expanded), textOnlyModel.id) }).toEqual({ view: "pi", expanded, warns: true });
			expect({ view: "package", expanded, warns: warnsAbout(draw(pkg, unsupported, cwd, expanded), textOnlyModel.id) }).toEqual({ view: "package", expanded, warns: true });
			expect({ view: "package", expanded, warns: warnsAbout(draw(pkg, supported, cwd, expanded), visionModel.id) }).toEqual({ view: "package", expanded, warns: false });
		}
	});

	// Pi 1.6.0's read result for a text-only model, as `piRead` returns it, so the
	// rows run on the package's pinned Pi too.
	const recorded = {
		content: [
			{ type: "text", text: "Read image file [image/png]" },
			{ type: "image", data: pngData, mimeType: "image/png" },
		],
		details: { imageUnsupportedByModel: textOnlyModel.id },
	};
	const seen = { content: recorded.content };
	const rows = [
		{ mode: "preview", result: recorded, warns: true },
		{ mode: "summary", result: recorded, warns: true },
		{ mode: "hidden", result: recorded, warns: true },
		{ mode: "preview", result: seen, warns: false },
		{ mode: "summary", result: seen, warns: false },
		{ mode: "hidden", result: seen, warns: false },
	];
	for (const row of rows) {
		test(`readOutputMode ${row.mode} ${row.warns ? "draws" : "draws no"} warning, collapsed and expanded`, () => {
			const cwd = tempCwd({ readOutputMode: row.mode });
			const pkg = createReadRenderers(cwd);
			for (const expanded of [false, true]) {
				expect({ expanded, warns: warnsAbout(draw(pkg, row.result, cwd, expanded), textOnlyModel.id) }).toEqual({ expanded, warns: row.warns });
			}
		});
	}
});
