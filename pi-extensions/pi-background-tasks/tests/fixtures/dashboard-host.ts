import { mock } from "bun:test";

// Only Pi's terminal peer is replaced. Dashboard layout and cache functions run unchanged.
export const dashboardHost = { commandWraps: 0 };
mock.module("@earendil-works/pi-tui", () => ({
	matchesKey: (input: string, key: string) => input === key,
	truncateToWidth: (text: string, width: number) => text.slice(0, width),
	visibleWidth: (text: string) => text.length,
	wrapTextWithAnsi: (text: string, width: number) => {
		if (text.startsWith("cache-me")) dashboardHost.commandWraps += 1;
		const lines = [];
		for (let index = 0; index < text.length; index += width) lines.push(text.slice(index, index + width));
		return lines;
	},
}));
