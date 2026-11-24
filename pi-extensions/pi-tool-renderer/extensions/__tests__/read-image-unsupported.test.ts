import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createReadToolDefinition, VERSION } from "@earendil-works/pi-coding-agent";

import { registerToolBatch } from "../tool-renderer/batch.js";
import { clearPackageConfigCache, recordProjectTrust } from "../tool-renderer/package-config.js";
import { clearStackState } from "../tool-renderer/stack.js";
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
	clearStackState();
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

/** One call per directory, so expanding redraws the same call as Pi does. */
function draw(renderers: any, result: any, cwd: string, expanded: boolean): string[] {
	const context = { args: { path: "image.png" }, cwd, invalidate() {}, showImages: false, state: {}, toolCallId: cwd };
	return renderers.renderResult(result, { expanded, isPartial: false }, theme, context).render(300);
}

/** tool_batch's view of one read child whose result is `result`. */
async function drawBatch(result: any, cwd: string, expanded: boolean): Promise<string[]> {
	let batch: any;
	registerToolBatch({ registerTool: (definition: unknown) => { batch = definition; } } as never, cwd);
	const executeTool = async () => ({ result, isError: false });
	const batchResult = await batch.execute("batch-1", { calls: [{ tool: "read", args: { path: "image.png" } }] }, undefined, undefined, { cwd, executeTool });
	return batch.renderResult(batchResult, { expanded, isPartial: false }, theme, { cwd }).render(300);
}

function warnsAbout(lines: string[], model: string): boolean {
	const warnings = lines.join("\n").match(/<warning>[^<]*<\/warning>/g) ?? [];
	return warnings.some((part) => part.includes(model));
}

/** A row that warns about no model has no warning-colored part at all. */
function warnsAtAll(lines: string[]): boolean {
	return lines.join("\n").includes("<warning>");
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
			expect({ view: "package", expanded, warns: warnsAtAll(draw(pkg, supported, cwd, expanded)) }).toEqual({ view: "package", expanded, warns: false });
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
	const views = [
		{ name: "readOutputMode preview", view: "read", config: { readOutputMode: "preview" } },
		{ name: "readOutputMode summary", view: "read", config: { readOutputMode: "summary" } },
		{ name: "readOutputMode hidden", view: "read", config: { readOutputMode: "hidden" } },
		{ name: "stacked rows", view: "read", config: { stackToolCalls: true, stackChildDisplay: "rows" } },
		{ name: "stacked headline", view: "read", config: { stackToolCalls: true, stackChildDisplay: "headline" } },
		{ name: "stacked anchor-list", view: "read", config: { stackToolCalls: true, stackChildDisplay: "anchor-list" } },
		{ name: "tool_batch", view: "batch", config: {} },
	];
	for (const row of views.flatMap((view) => [{ ...view, result: recorded, warns: true }, { ...view, result: seen, warns: false }])) {
		test(`${row.name} ${row.warns ? "draws" : "draws no"} warning, collapsed and expanded`, async () => {
			const cwd = tempCwd(row.config);
			const pkg = createReadRenderers(cwd);
			for (const expanded of [false, true]) {
				const lines = row.view === "batch" ? await drawBatch(row.result, cwd, expanded) : draw(pkg, row.result, cwd, expanded);
				const warns = row.warns ? warnsAbout(lines, textOnlyModel.id) : warnsAtAll(lines);
				expect({ expanded, warns }).toEqual({ expanded, warns: row.warns });
			}
		});
	}
});
