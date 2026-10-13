import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import ts from "typescript";
import { buildModels } from "../src/models.js";
import { buildClaudeQueryOptions } from "../src/query-options.js";
import { assertSourceControl } from "./lib/source-control.mjs";

const fixtureModel = (id) => ({
	id, name: id, reasoning: true, input: ["text", "image"],
	contextWindow: 123, maxTokens: 456, thinkingLevelMap: { xhigh: "xhigh" },
	cost: { input: 1, output: 1 }, baseUrl: "https://api.anthropic.com",
	api: "anthropic", provider: "anthropic", headers: { "x-api-key": "fixture" },
});

describe("runtime models", () => {
	it("offers the fixture source model and leaves its fallback with Claude Code", () => {
		const models = buildModels([fixtureModel("claude-fable-99-1"), fixtureModel("claude-opus-98")]);
		assert.deepEqual(models.map((model) => model.id), ["claude-fable-99-1", "claude-opus-98"]);
		for (const model of models) {
			assert.equal(model.contextWindow, 123);
			assert.equal(model.maxTokens, 456);
			assert.deepEqual(model.thinkingLevelMap, { xhigh: "xhigh" });
			assert.deepEqual(model.cost, { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
			for (const key of ["baseUrl", "api", "provider", "headers"]) assert.equal(Object.hasOwn(model, key), false);
			const { queryOptions } = buildClaudeQueryOptions({
				cwd: process.cwd(), queryModel: model,
				bridgeConfig: {}, resumeSessionId: null,
			});
			assert.equal(queryOptions.model, model.id);
			assert.equal(Object.hasOwn(queryOptions, "fallbackModel"), false);
		}
		assert.deepEqual(buildModels([]), []);
	});

	it("has no versioned model IDs in bridge source or package configuration", () => {
		const root = new URL("../src/", import.meta.url);
		const files = readdirSync(root, { recursive: true }).filter((path) => path.endsWith(".ts"));
		assert.ok(files.includes("models.ts"));
		const found = [];
		for (const path of [...files.map((file) => new URL(file, root)), new URL("../package.json", import.meta.url)]) {
			const scanner = ts.createScanner(ts.ScriptTarget.Latest, true, ts.LanguageVariant.Standard, readFileSync(path, "utf8"));
			for (let kind = scanner.scan(); kind !== ts.SyntaxKind.EndOfFileToken; kind = scanner.scan()) {
				if (/claude-(?:[a-z]+-)*[0-9]/.test(scanner.getTokenText())) found.push(path.pathname);
			}
		}
		assert.deepEqual(found, []);
	});

	it("rejects a restored constant list in the picker and source scan", () => {
		assertSourceControl({
			source: "src/models.ts",
			before: "return piAiModels.map(",
			after: 'return piAiModels.filter((model) => ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5"].includes(model.id)).map(',
			suite: "unit-models.mjs",
			pattern: "fixture source model|no versioned model IDs",
			failure: /(?:not ok|✖) .*fixture source model[\s\S]*(?:not ok|✖) .*no versioned model IDs/,
		});
	});

	it("rejects a bridge fallback override", () => {
		assertSourceControl({
			source: "src/query-options.ts",
			before: "model: queryModel.id,",
			after: 'model: queryModel.id, fallbackModel: "opus",',
			suite: "unit-models.mjs",
			pattern: "fixture source model",
			failure: /(?:not ok|✖) .*fixture source model/,
		});
	});
});
