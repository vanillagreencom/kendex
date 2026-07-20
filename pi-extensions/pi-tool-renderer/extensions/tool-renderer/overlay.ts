export const TOOL_RENDER_OVERLAY_CHECK_SYMBOL = Symbol.for("vstack.pi-tool-renderer.overlay-check");
export const RESERVED_IMAGE_ROW_MARKER = "\x1b[0m\x1b[0m";

const VSTACK_MODAL_LOCK_SYMBOL = Symbol.for("vstack.pi.modal-lock");

interface VstackModalLock {
	depth: number;
}

export function floatingOverlayActive(context: any): boolean {
	const checker = context?.[TOOL_RENDER_OVERLAY_CHECK_SYMBOL];
	if (typeof checker === "function") {
		try {
			return checker() === true;
		} catch {
			return false;
		}
	}
	const lock = (globalThis as unknown as Record<PropertyKey, unknown>)[VSTACK_MODAL_LOCK_SYMBOL] as VstackModalLock | undefined;
	return typeof lock?.depth === "number" && lock.depth > 0;
}
