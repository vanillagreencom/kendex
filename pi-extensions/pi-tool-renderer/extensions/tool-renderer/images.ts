import { convertToPng } from "@earendil-works/pi-coding-agent";
import { Container, getCapabilities, Image, Spacer } from "@earendil-works/pi-tui";

import { floatingOverlayActive, RESERVED_IMAGE_ROW_MARKER } from "./overlay.js";
import { readImageMode } from "./settings.js";

type ImageConversionResult = Awaited<ReturnType<typeof convertToPng>>;

function ignoreConversionError(): void {}

class OverlayAwareImage {
	private context: any;

	constructor(private readonly image: Image, context: any) {
		this.context = context;
	}

	setContext(context: any): void {
		this.context = context;
	}

	invalidate(): void {
		this.image.invalidate();
	}

	render(width: number): string[] {
		const lines = this.image.render(width);
		if (!floatingOverlayActive(this.context)) return lines;
		return lines.map((_line, index) => index === 0 ? RESERVED_IMAGE_ROW_MARKER : "");
	}
}

interface ReadImageBlock {
	type: "image";
	data: string;
	mimeType: string;
}

interface ReadImageCacheEntry {
	sourceData: string;
	sourceMimeType: string;
	converted?: NonNullable<ImageConversionResult>;
	conversionStarted?: boolean;
	renderedData?: string;
	renderedMimeType?: string;
	component?: OverlayAwareImage;
}

interface ReadImageRenderState {
	entries: Map<number, ReadImageCacheEntry>;
}

function readImageBlocks(result: any): ReadImageBlock[] {
	if (!Array.isArray(result?.content)) return [];
	return result.content.filter(
		(part: any): part is ReadImageBlock => part?.type === "image" && typeof part.data === "string" && typeof part.mimeType === "string",
	);
}

function readImageRenderState(context: any): ReadImageRenderState {
	const state = context?.state;
	if (!state || typeof state !== "object") return { entries: new Map() };
	const record = state as Record<string, unknown>;
	if (!record.vstackReadImages || typeof record.vstackReadImages !== "object") {
		record.vstackReadImages = { entries: new Map<number, ReadImageCacheEntry>() };
	}
	return record.vstackReadImages as ReadImageRenderState;
}

function readImageComponent(block: ReadImageBlock, index: number, theme: any, context: any): OverlayAwareImage | undefined {
	const state = readImageRenderState(context);
	let entry = state.entries.get(index);
	if (!entry || entry.sourceData !== block.data || entry.sourceMimeType !== block.mimeType) {
		entry = { sourceData: block.data, sourceMimeType: block.mimeType };
		state.entries.set(index, entry);
	}

	let data = block.data;
	let mimeType = block.mimeType;
	if (getCapabilities().images === "kitty" && mimeType !== "image/png") {
		if (!entry.converted) {
			if (!entry.conversionStarted) {
				entry.conversionStarted = true;
				void convertToPng(data, mimeType).then((converted: ImageConversionResult) => {
					if (state.entries.get(index) !== entry || !converted) return;
					entry.converted = converted;
					entry.component = undefined;
					context?.invalidate?.();
				}, ignoreConversionError);
			}
			return undefined;
		}
		data = entry.converted.data;
		mimeType = entry.converted.mimeType;
	}

	if (!entry.component || entry.renderedData !== data || entry.renderedMimeType !== mimeType) {
		entry.renderedData = data;
		entry.renderedMimeType = mimeType;
		const image = new Image(data, mimeType, { fallbackColor: (text: string) => theme.fg("toolOutput", text) });
		entry.component = new OverlayAwareImage(image, context);
	} else {
		entry.component.setContext(context);
	}
	return entry.component;
}

export function renderReadImages(component: any, result: any, expanded: boolean, theme: any, context: any, cwd: string): any {
	const effectiveCwd = context?.cwd ?? cwd;
	const mode = readImageMode(effectiveCwd);
	if (mode === "off" || (mode === "on" && !expanded) || context?.showImages !== false) return component;
	if (!getCapabilities().images) return component;
	const blocks = readImageBlocks(result);
	if (blocks.length === 0) return component;

	const container = new Container();
	container.addChild(component);
	let hasImages = false;
	for (const [index, block] of blocks.entries()) {
		const image = readImageComponent(block, index, theme, context);
		if (!image) continue;
		container.addChild(new Spacer(1));
		container.addChild(image);
		hasImages = true;
	}
	return hasImages ? container : component;
}
