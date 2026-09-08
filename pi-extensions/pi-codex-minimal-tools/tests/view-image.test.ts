import assert from "node:assert/strict";
import { mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { validateImagePath } from "../src/tools/view-image.js";
import { world } from "./helpers/world.js";

for (const row of [
	{ name: "at prefix", kind: "image", path: "@image.png", workspaceOnly: false, detail: "high" },
	{ name: "directory", kind: "directory", path: "dir", workspaceOnly: false, code: "IMAGE_DIRECTORY" },
	{ name: "non-image", kind: "text", path: "notes.txt", workspaceOnly: false, code: "IMAGE_TYPE" },
	{ name: "relative escape", kind: "outside", path: "../secret.png", workspaceOnly: true, code: "IMAGE_PATH_OUTSIDE" },
	{ name: "absolute escape", kind: "outside", path: "absolute", workspaceOnly: true, code: "IMAGE_PATH_OUTSIDE" },
	{ name: "symlink escape", kind: "symlink", path: "linked.png", workspaceOnly: true, code: "IMAGE_PATH_OUTSIDE" },
	{ name: "outside allowed by default", kind: "outside", path: "absolute", workspaceOnly: undefined },
] as const) {
	test(`validateImagePath: ${row.name}`, async (t) => {
		const { cwd, root } = world(t);
		const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
		const outside = join(root, "secret.png");
		if (row.kind === "directory") mkdirSync(join(cwd, "dir"));
		else if (row.kind === "text") writeFileSync(join(cwd, "notes.txt"), "hello");
		else if (row.kind === "image") writeFileSync(join(cwd, "image.png"), bytes);
		else {
			writeFileSync(outside, bytes);
			if (row.kind === "symlink") symlinkSync(outside, join(cwd, "linked.png"));
		}
		const input = { path: row.path === "absolute" ? outside : row.path, detail: "detail" in row ? row.detail : undefined };
		const validate = () => validateImagePath(input, cwd, { workspaceOnly: row.workspaceOnly });
		if ("code" in row) await assert.rejects(validate, { code: row.code, path: input.path });
		else {
			const result = await validate();
			assert.equal(result.mimeType, "image/png");
			assert.equal(result.absolutePath, row.kind === "outside" ? outside : join(cwd, "image.png"));
			if (row.kind === "image") {
				assert.equal(result.displayPath, "image.png");
				assert.equal(result.detail, "high");
			}
		}
	});
}
