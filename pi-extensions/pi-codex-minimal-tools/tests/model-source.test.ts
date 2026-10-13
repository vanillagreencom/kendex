import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import ts from "typescript";

function versionedModelLiterals(text: string): string[] {
	const source = ts.createSourceFile("source.ts", text.replace(/\r\n/g, "\n"), ts.ScriptTarget.Latest, true);
	const found: string[] = [];
	const visit = (node: ts.Node): void => {
		// Image API selectors are existing public settings, outside conversation-model detection.
		if ((ts.isStringLiteralLike(node) || ts.isRegularExpressionLiteral(node)) && /\b(?:gpt-\d|o\d)/.test(node.getText(source))) found.push(node.getText(source));
		ts.forEachChild(node, visit);
	};
	visit(source);
	return found;
}

test("package source has no versioned conversation model identities", () => {
	const root = fileURLToPath(new URL("../src", import.meta.url));
	const paths = readdirSync(root, { recursive: true, withFileTypes: true }).filter(entry => entry.isFile() && entry.name.endsWith(".ts")).map(entry => join(entry.parentPath, entry.name));
	assert.ok(paths.includes(join(root, "activation.ts")));
	assert.ok(paths.includes(join(root, "provider-shim.ts")));
	const found = paths.flatMap(path => versionedModelLiterals(readFileSync(path, "utf8")).map(literal => ({ path, literal })));
	assert.deepEqual(found, []);
});

test("source scan rejects planted model identities and permits comments", () => {
	for (const literal of ['"gpt-5.2"', '"o4-mini"', '/^gpt-5\\.1/']) {
		assert.deepEqual(versionedModelLiterals(`const model = ${literal};`), [literal]);
		assert.deepEqual(versionedModelLiterals(`// ${literal}\n/* ${literal} */ const provider = "openai";`), []);
	}
	assert.deepEqual(versionedModelLiterals('const imageModel = "gpt-image-2";'), []);
});
