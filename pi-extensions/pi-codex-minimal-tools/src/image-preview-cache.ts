import { readFile } from "node:fs/promises";
import { getImageDimensions } from "@earendil-works/pi-tui";

export interface CachedImagePreview {
	data: string;
	mimeType: string;
	bytes: number;
	widthPx?: number;
	heightPx?: number;
}

/** Base64 characters of image previews held at once. Past it the least
 *  recently shown previews are dropped and read from disk again when shown. */
export const IMAGE_PREVIEW_CACHE_MAX_CHARS = 16 * 1024 * 1024;

export function makeCachedImagePreview(data: string, mimeType: string, bytes?: number): CachedImagePreview {
	const dimensions = getImageDimensions(data, mimeType) ?? undefined;
	return { data, mimeType, bytes: bytes ?? Buffer.from(data, "base64").byteLength, widthPx: dimensions?.widthPx, heightPx: dimensions?.heightPx };
}

/**
 * Previews of saved generated images, keyed by absolute path. A render never
 * reads the file itself: a missing preview is loaded in the background, and
 * the render after the load shows it. A file that cannot be read is not tried
 * again until the cache is cleared.
 */
export class ImagePreviewCache {
	/** Least recently used first. */
	private readonly previews = new Map<string, CachedImagePreview>();
	private readonly loading = new Map<string, Promise<void>>();
	private readonly unreadable = new Set<string>();
	private chars = 0;

	get(path: string): CachedImagePreview | undefined {
		const preview = this.previews.get(path);
		if (!preview) return undefined;
		this.previews.delete(path);
		this.previews.set(path, preview);
		return preview;
	}

	set(path: string, preview: CachedImagePreview): void {
		this.forget(path);
		this.previews.set(path, preview);
		this.chars += preview.data.length;
		for (const [oldest, held] of this.previews) {
			if (this.chars <= IMAGE_PREVIEW_CACHE_MAX_CHARS || oldest === path) break;
			this.previews.delete(oldest);
			this.chars -= held.data.length;
		}
	}

	/** Start reading `path` in the background unless it is held, being read, or
	 *  unreadable. The returned promise settles when that read is done. */
	load(path: string, mimeType: string): Promise<void> {
		if (this.previews.has(path) || this.unreadable.has(path)) return Promise.resolve();
		const pending = this.loading.get(path);
		if (pending) return pending;
		const read = readFile(path)
			.then((buffer) => this.set(path, makeCachedImagePreview(buffer.toString("base64"), mimeType, buffer.byteLength)))
			.catch(() => { this.unreadable.add(path); })
			.finally(() => { this.loading.delete(path); });
		this.loading.set(path, read);
		return read;
	}

	clear(): void {
		this.previews.clear();
		this.unreadable.clear();
		this.chars = 0;
	}

	private forget(path: string): void {
		const held = this.previews.get(path);
		if (!held) return;
		this.previews.delete(path);
		this.chars -= held.data.length;
	}
}
