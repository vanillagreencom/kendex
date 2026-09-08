import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { viewImage } from "../src/tools/view-image.js";
import { world } from "./helpers/world.js";

test("viewImage emits the selected file as an image block", async (t) => {
	const { cwd } = world(t);
	const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
	writeFileSync(join(cwd, "image.png"), bytes);
	const result = await viewImage({ path: "image.png" }, cwd);
	assert.equal(result.content[0]?.type, "image");
	assert.equal(result.content[0]?.mimeType, "image/png");
	assert.equal(typeof result.content[0]?.data, "string");
	assert.equal(result.content[0]?.data, bytes.toString("base64"));
});
