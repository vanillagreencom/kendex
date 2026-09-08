import { stat, readFile, realpath } from "node:fs/promises";
import { extname, isAbsolute, relative, resolve } from "node:path";

export type ImageDetail = "auto" | "low" | "high" | "original";

export interface ViewImageInput {
	path: string;
	detail?: ImageDetail;
}

export interface ViewImageOptions {
	workspaceOnly?: boolean;
}

export interface ValidatedImage {
	absolutePath: string;
	displayPath: string;
	mimeType: string;
	sizeBytes: number;
	detail: ImageDetail;
}

const IMAGE_MIME_BY_EXT: Record<string, string> = {
	".png": "image/png",
	".jpg": "image/jpeg",
	".jpeg": "image/jpeg",
	".gif": "image/gif",
	".webp": "image/webp",
	".bmp": "image/bmp",
	".tif": "image/tiff",
	".tiff": "image/tiff",
	".svg": "image/svg+xml",
};

function assertWithinCwd(absolutePath: string, cwd: string, displayPath: string): void {
	const cwdAbsolute = resolve(cwd);
	const rel = relative(cwdAbsolute, absolutePath);
	if (rel === "" || (!rel.startsWith("..") && !isAbsolute(rel))) return;
	throw Object.assign(new Error(`image_path_outside=${displayPath}\nview_image path escapes the workspace: ${displayPath}`), { code: "IMAGE_PATH_OUTSIDE", path: displayPath });
}

export function normalizeImagePath(pathValue: string, cwd: string, options?: ViewImageOptions): { absolutePath: string; displayPath: string } {
	let cleaned = pathValue.trim();
	if ((cleaned.startsWith('"') && cleaned.endsWith('"')) || (cleaned.startsWith("'") && cleaned.endsWith("'"))) cleaned = cleaned.slice(1, -1);
	if (cleaned.startsWith("@")) cleaned = cleaned.slice(1);
	const absolutePath = resolve(cwd, cleaned);
	if (options?.workspaceOnly) assertWithinCwd(absolutePath, cwd, cleaned);
	return { absolutePath, displayPath: cleaned };
}

export function mimeTypeForImagePath(path: string): string | undefined {
	return IMAGE_MIME_BY_EXT[extname(path).toLowerCase()];
}

export async function validateImagePath(input: ViewImageInput, cwd: string, options?: ViewImageOptions): Promise<ValidatedImage> {
	if (!input || typeof input.path !== "string" || input.path.trim().length === 0) throw new Error("view_image requires a non-empty path.");
	const detail = input.detail ?? "auto";
	if (!["auto", "low", "high", "original"].includes(detail)) throw new Error(`Unsupported image detail: ${String(input.detail)}`);
	const normalized = normalizeImagePath(input.path, cwd, options);
	let fileStat;
	try {
		fileStat = await stat(normalized.absolutePath);
	} catch {
		throw new Error(`Image not found: ${normalized.displayPath}`);
	}
	if (fileStat.isDirectory()) throw Object.assign(new Error(`image_directory=${normalized.displayPath}\nview_image expected a file but got a directory: ${normalized.displayPath}`), { code: "IMAGE_DIRECTORY", path: normalized.displayPath });
	if (!fileStat.isFile()) throw new Error(`view_image expected a regular image file: ${normalized.displayPath}`);
	if (options?.workspaceOnly) {
		try {
			assertWithinCwd(await realpath(normalized.absolutePath), await realpath(cwd), normalized.displayPath);
		} catch (error) {
			if (error instanceof Error && (error as NodeJS.ErrnoException).code === "IMAGE_PATH_OUTSIDE") throw error;
			throw new Error(`Unable to validate image path: ${normalized.displayPath}`);
		}
	}
	const mimeType = mimeTypeForImagePath(normalized.absolutePath);
	if (!mimeType) throw Object.assign(new Error(`image_type=${normalized.displayPath}\nUnsupported image file type for view_image: ${normalized.displayPath}`), { code: "IMAGE_TYPE", path: normalized.displayPath });
	return { ...normalized, detail, mimeType, sizeBytes: fileStat.size };
}

export async function viewImage(input: ViewImageInput, cwd: string, options?: ViewImageOptions) {
	const image = await validateImagePath(input, cwd, options);
	const data = await readFile(image.absolutePath, "base64");
	return {
		content: [{ type: "image", data, mimeType: image.mimeType, detail: image.detail }],
		details: image,
	};
}

export const viewImageToolSchema = {
	type: "object",
	additionalProperties: false,
	properties: {
		path: { type: "string", description: "Path to the local image file. Relative paths resolve against ctx.cwd; a leading @ is accepted and stripped." },
		detail: { type: "string", enum: ["auto", "low", "high", "original"], description: "Image detail hint. Defaults to auto." },
	},
	required: ["path"],
};
