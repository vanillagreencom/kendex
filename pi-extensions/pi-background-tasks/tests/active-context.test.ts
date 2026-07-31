import { describe, expect, test } from "bun:test";
import { shouldAdoptActiveContext } from "../extensions/active-context.js";
import { shouldRenderBackgroundWidget } from "../extensions/widget-visibility.js";

describe("shouldAdoptActiveContext", () => {
	test("adopts the first context seen", () => {
		expect(shouldAdoptActiveContext(null, { hasUI: true })).toBe(true);
		expect(shouldAdoptActiveContext(null, { hasUI: false })).toBe(true);
		expect(shouldAdoptActiveContext(undefined, { hasUI: false })).toBe(true);
	});

	test("a UI context always replaces the retained one", () => {
		expect(shouldAdoptActiveContext({ hasUI: false }, { hasUI: true })).toBe(true);
		expect(shouldAdoptActiveContext({ hasUI: true }, { hasUI: true })).toBe(true);
	});

	// pi#7214: direct RPC bash now reaches the user_bash handler. Its context has
	// no UI, and adopting it used to blank the mini-dashboard on the next refresh.
	test("a non-UI context does not replace a retained UI context", () => {
		expect(shouldAdoptActiveContext({ hasUI: true }, { hasUI: false })).toBe(false);
		expect(shouldAdoptActiveContext({ hasUI: true }, {})).toBe(false);
	});

	test("headless sessions keep adopting non-UI contexts", () => {
		expect(shouldAdoptActiveContext({ hasUI: false }, { hasUI: false })).toBe(true);
	});

	test("retaining the UI context keeps the widget rendering after an RPC bash", () => {
		const uiCtx = { hasUI: true };
		const rpcCtx = { hasUI: false };
		const retained = shouldAdoptActiveContext(uiCtx, rpcCtx) ? rpcCtx : uiCtx;
		expect(
			shouldRenderBackgroundWidget({
				hasUi: retained.hasUI,
				mode: "compact",
				showWidget: true,
				trackedTaskCount: 1,
				visibleTaskCount: 1,
			}),
		).toBe(true);
	});
});
