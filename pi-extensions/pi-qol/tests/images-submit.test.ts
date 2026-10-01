import { expect, spyOn, test } from "bun:test";
import { appendFileSync, closeSync, ftruncateSync, mkdirSync, openSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import qolDefault from "../extensions/qol.ts";
import * as imagesRuntime from "../extensions/qol/images.ts";
import { makeCtx, makeFakeApi } from "./fake-pi.ts";
import { imageReadSpies, runtimeCopy, scratch } from "./search-fixture.ts";

const { imageContentsForPaths } = imagesRuntime;

function sparseImage(path: string, bytes: number): void {
	const fd = openSync(path, "w");
	try { ftruncateSync(fd, bytes); } finally { closeSync(fd); }
}

test("input refuses a 50 MiB image without reading it and restores only an empty editor", async () => {
	const root = scratch();
	try {
		const path = join(root, "large.png");
		sparseImage(path, 50 * 1024 * 1024);
		const check = async (factory: typeof qolDefault) => {
			for (const draft of ["", "new unsent draft"]) {
				const api = makeFakeApi(); factory(api.api);
				let editor = "";
				const errors: string[] = [];
				const ctx = makeCtx({ cwd: root, hasUI: true, ui: { ...makeCtx().ui, getEditorText: () => editor, setEditorText: (text: string) => { editor = text; }, notify: (text: string) => { errors.push(text); } } });
				api.handlers.session_tree!({ type: "session_tree" }, ctx);
				let release!: () => void;
				let entered!: () => void;
				const blocked = new Promise<void>((resolve) => { release = resolve; });
				const opening = new Promise<void>((resolve) => { entered = resolve; });
				const spies = imageReadSpies(undefined, async () => { entered(); await blocked; });
				try {
					const pending = api.handlers.input!({ source: "interactive", text: path }, ctx);
					await opening;
					editor = draft;
					release();
					const result = await pending;
					expect(result.action).toBe("handled");
					expect(errors[0]).toContain("IMAGE_SIZE_LIMIT");
					expect(editor).toBe(draft || path);
					expect(spies.count()).toBe(0);
					expect(spies.closed()).toBe(true);
				} finally { release(); spies.restore(); }
			}
		};
		await check(qolDefault);
		for (const patch of [
			{ file: "qol/images.ts", from: "total > SUBMITTED_IMAGES_MAX_BYTES", to: "total > Number.MAX_SAFE_INTEGER" },
			{ file: "qol.ts", from: 'return { action: "handled" };\n\t\t}\n\t});', to: 'return { action: "continue" };\n\t\t}\n\t});' },
			{ file: "qol.ts", from: 'ctx.hasUI && ctx.ui.getEditorText() === ""', to: "ctx.hasUI" },
		]) await runtimeCopy<{ default: typeof qolDefault }>("qol.ts", [patch], async (mutant) => { await expect(check(mutant.default)).rejects.toThrow(); });
	} finally { rmSync(root, { recursive: true, force: true }); }
});

test("headless input reports image refusal on stderr and stays handled", async () => {
	const root = scratch();
	try {
		const path = join(root, "large.png");
		sparseImage(path, 50 * 1024 * 1024);
		const check = async (factory: typeof qolDefault) => {
			for (const mode of ["print", "json"]) {
				const api = makeFakeApi(); factory(api.api);
				const diagnostics = spyOn(console, "error").mockImplementation(() => {});
				const spies = imageReadSpies();
				try {
					const result = await api.handlers.input!({ source: "interactive", text: path }, makeCtx({ cwd: root, mode, hasUI: false }));
					expect(result.action).toBe("handled");
					expect(diagnostics).toHaveBeenCalledTimes(1);
					expect(diagnostics.mock.calls[0]?.[0]).toContain("IMAGE_SIZE_LIMIT");
					expect(spies.count()).toBe(0);
				} finally { diagnostics.mockRestore(); spies.restore(); }
			}
		};
		await check(qolDefault);
		await runtimeCopy<{ default: typeof qolDefault }>("qol.ts", [{ file: "qol.ts", from: "if (!ctx.hasUI) console.error(message);", to: "if (!ctx.hasUI) void message;" }], async (mutant) => { await expect(check(mutant.default)).rejects.toThrow(); });
	} finally { rmSync(root, { recursive: true, force: true }); }
});

test("image budget adds every file and existing clipboard image before any read", async () => {
	const root = scratch();
	try {
		const paths = [join(root, "a.png"), join(root, "b.png")];
		paths.forEach((path) => sparseImage(path, 11 * 1024 * 1024));
		for (const row of [
			{ paths, existing: [], from: "total += stat.size;", to: "total = stat.size;" },
			{ paths: [paths[0]!], existing: [{ data: Buffer.alloc(11 * 1024 * 1024).toString("base64") }], from: "sum + Buffer.byteLength(image.data, \"base64\")", to: "sum" },
		]) {
			const check = async (load: typeof imageContentsForPaths) => {
				const spies = imageReadSpies();
				try {
					await expect(load(row.paths, row.existing)).rejects.toThrow("IMAGE_SIZE_LIMIT");
					expect(spies.count()).toBe(0);
					expect(spies.closed()).toBe(true);
				} finally { spies.restore(); }
			};
			await check(imageContentsForPaths);
			await runtimeCopy<{ imageContentsForPaths: typeof imageContentsForPaths }>("qol/images.ts", [{ file: "qol/images.ts", from: row.from, to: row.to }], async (mutant) => { await expect(check(mutant.imageContentsForPaths)).rejects.toThrow(); });
		}
	} finally { rmSync(root, { recursive: true, force: true }); }
});

test("a file that grows after stat is refused before encoding", async () => {
	const root = scratch();
	try {
		const path = join(root, "growing.png");
		const check = async (load: typeof imageContentsForPaths) => {
			writeFileSync(path, "small");
			const spies = imageReadSpies(() => appendFileSync(path, "growth"));
			try {
				await expect(load([path])).rejects.toThrow("IMAGE_SIZE_CHANGED");
				expect(spies.closed()).toBe(true);
			} finally { spies.restore(); }
		};
		await check(imageContentsForPaths);
		await runtimeCopy<{ imageContentsForPaths: typeof imageContentsForPaths }>("qol/images.ts", [{ file: "qol/images.ts", from: "offset > file.size", to: "offset > Number.MAX_SAFE_INTEGER" }], async (mutant) => { await expect(check(mutant.imageContentsForPaths)).rejects.toThrow(); });
	} finally { rmSync(root, { recursive: true, force: true }); }
});

test("image reads are asynchronous and valid bytes retain MIME type; directories refuse", async () => {
	const root = scratch();
	try {
		const path = join(root, "small.png");
		writeFileSync(path, "image bytes");
		const images = imageContentsForPaths([path]);
		expect(images).toBeInstanceOf(Promise);
		expect(await images).toEqual([{ type: "image", data: Buffer.from("image bytes").toString("base64"), mimeType: "image/png" }]);
		const directory = join(root, "directory.png"); mkdirSync(directory);
		const check = async (load: typeof imageContentsForPaths) => { await expect(load([directory])).rejects.toThrow("IMAGE_NOT_FILE"); };
		await check(imageContentsForPaths);
		await runtimeCopy<{ imageContentsForPaths: typeof imageContentsForPaths }>("qol/images.ts", [{ file: "qol/images.ts", from: "!stat.isFile()", to: "stat.isFile() && false" }], async (mutant) => { await expect(check(mutant.imageContentsForPaths)).rejects.toThrow(); });
	} finally { rmSync(root, { recursive: true, force: true }); }
});
