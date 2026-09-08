import assert from "node:assert/strict";
import test from "node:test";
import { parseImageGenCommandArgs } from "../src/background-image-generation.js";

for (const row of [
	{ input: "make it green @icon.png 'with soft shadows' @refs/logo.webp", prompt: "make it green with soft shadows", imagePaths: ["icon.png", "refs/logo.webp"] },
	{ input: "make this button green /tmp/pi-clipboard-abc.png", prompt: "make this button green", imagePaths: ["/tmp/pi-clipboard-abc.png"] },
	{ input: "edit file:///tmp/reference.webp.", prompt: "edit", imagePaths: ["/tmp/reference.webp"] },
]) {
	test(`image command arguments: ${row.input}`, () => {
		assert.deepEqual(parseImageGenCommandArgs(row.input), { prompt: row.prompt, imagePaths: row.imagePaths });
	});
}
