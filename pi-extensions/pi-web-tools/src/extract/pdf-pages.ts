import { execFile } from "node:child_process";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/** Pixel budget for one rasterized page; `pageScaleArgs` lowers the DPI of a document whose largest page would exceed it. */
export const MAX_PAGE_PIXELS = 4_000_000;

export interface PdfPageImage {
	type: "image";
	mimeType: "image/png";
	data: string;
	pageNumber: number;
}

export interface RasterizeOptions {
	maxPages?: number;
	dpi?: number;
	pdftoppmCommand?: string;
	pdfinfoCommand?: string;
}

export interface RasterizeResult {
	pageCount: number;
	images: PdfPageImage[];
	truncated: boolean;
}

interface PageLayout {
	pageCount?: number;
	/** The largest page area in square points among the pages read; absent when pdfinfo printed no page size. */
	maxPageArea?: number;
}

async function readPageLayout(pdfPath: string, lastPage: number, command = "pdfinfo"): Promise<PageLayout> {
	try {
		const { stdout } = await execFileAsync(command, ["-f", "1", "-l", String(lastPage), pdfPath], { maxBuffer: 1024 * 1024 });
		const text = String(stdout ?? "");
		const count = text.match(/^Pages:\s*(\d+)/m);
		const areas = [...text.matchAll(/^Page\s+\d+\s+size:\s*([\d.]+)\s*x\s*([\d.]+)\s*pts/gm)].map((match) => Number(match[1]) * Number(match[2]));
		return { pageCount: count?.[1] ? Number(count[1]) : undefined, maxPageArea: areas.length ? Math.max(...areas) : undefined };
	} catch {
		return {};
	}
}

/** The pdftoppm scaling arguments for the page pixel budget: the requested DPI, lowered so the largest page's area at that DPI
 * stays within MAX_PAGE_PIXELS, or a square box of MAX_PAGE_PIXELS when pdfinfo gave no page size. */
export function pageScaleArgs(dpi: number, maxPageArea: number | undefined): string[] {
	const fitDpi = maxPageArea !== undefined && maxPageArea > 0 ? Math.floor(72 * Math.sqrt(MAX_PAGE_PIXELS / maxPageArea)) : 0;
	return fitDpi >= 1 ? ["-r", String(Math.min(dpi, fitDpi))] : ["-scale-to", String(Math.floor(Math.sqrt(MAX_PAGE_PIXELS)))];
}

export async function rasterizePdfPages(buffer: ArrayBuffer | Uint8Array, options: RasterizeOptions = {}): Promise<RasterizeResult> {
	const maxPages = Math.max(1, Math.min(20, options.maxPages ?? 5));
	const dpi = Math.max(72, Math.min(300, options.dpi ?? 150));
	const command = options.pdftoppmCommand ?? "pdftoppm";
	const dir = await mkdtemp(join(tmpdir(), "pi-web-tools-pdf-pages-"));
	const inputPath = join(dir, "input.pdf");
	try {
		await writeFile(inputPath, Buffer.from(buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer)));
		const layout = await readPageLayout(inputPath, maxPages, options.pdfinfoCommand);
		const pageCount = layout.pageCount ?? maxPages;
		const lastPage = Math.min(pageCount, maxPages);
		await execFileAsync(command, [
			"-png",
			// pdfinfo's page size is the CropBox; rendering the same box keeps each page within the pixel budget.
			"-cropbox",
			...pageScaleArgs(dpi, layout.maxPageArea),
			"-f", "1",
			"-l", String(lastPage),
			inputPath,
			join(dir, "page"),
		], { maxBuffer: 200 * 1024 * 1024 });
		const files = (await readdir(dir)).filter((name) => name.startsWith("page-") && name.endsWith(".png")).sort();
		const images: PdfPageImage[] = [];
		for (const file of files) {
			const match = file.match(/^page-(\d+)\.png$/);
			if (!match) continue;
			const data = await readFile(join(dir, file));
			images.push({ type: "image", mimeType: "image/png", data: data.toString("base64"), pageNumber: Number(match[1]) });
		}
		return { pageCount, images, truncated: pageCount > lastPage };
	} finally {
		await rm(dir, { recursive: true, force: true }).catch(() => undefined);
	}
}

export function looksLikeScannedPdf(text: string, byteLength: number): boolean {
	const trimmed = text.replace(/\s+/g, " ").trim();
	if (!trimmed) return true;
	if (byteLength > 5000 && trimmed.length < 200) return true;
	return false;
}
