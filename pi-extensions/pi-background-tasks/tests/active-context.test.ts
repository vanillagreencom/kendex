import { expect, test } from "bun:test";
import { shouldAdoptActiveContext } from "../extensions/active-context.js";
import { shouldRenderBackgroundWidget } from "../extensions/widget-visibility.js";

test("context adoption retains UI while accepting first and headless contexts", () => {
	expect.hasAssertions();
	for (const [name, current, incoming, expected] of [
		["first UI context", null, { hasUI: true }, true],
		["first headless context", null, { hasUI: false }, true],
		["undefined retained context", undefined, { hasUI: false }, true],
		["UI replaces headless context", { hasUI: false }, { hasUI: true }, true],
		["UI replaces UI context", { hasUI: true }, { hasUI: true }, true],
		["headless context preserves UI", { hasUI: true }, { hasUI: false }, false],
		["missing UI flag preserves UI", { hasUI: true }, {}, false],
		["headless context replaces headless context", { hasUI: false }, { hasUI: false }, true],
	] as const) {
		expect(shouldAdoptActiveContext(current, incoming), name).toBe(expected);
	}
});

test("retained UI context keeps the composed widget decision visible after headless input", () => {
	expect.hasAssertions();
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
