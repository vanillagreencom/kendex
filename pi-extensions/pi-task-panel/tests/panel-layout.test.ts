import { expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clearPackageConfigCache } from "../extensions/package-config.js";
import { fakeCtx, fakePi, mockPiModules } from "./lib/fake-pi.js";

mockPiModules();

test("panel reuses layout and sorted order until resize, host invalidation or a state mutation", async () => {
	const base = realpathSync(mkdtempSync(join(tmpdir(), "task-panel-layout-")));
	const previous = process.env.PI_CODING_AGENT_DIR;
	const globals = globalThis as unknown as Record<symbol, unknown>;
	const registry = Symbol.for("kendex.pi.mini-dashboard-stack");
	const previousRegistry = globals[registry];
	delete globals[registry];
	process.env.PI_CODING_AGENT_DIR = base;
	clearPackageConfigCache();
	type Widget = { render(width: number): string[]; invalidate(): void; dispose?(): void };
	let widget: Widget | undefined;
	let styles = 0;
	let color = "";
	const theme = { fg: (_token: string, text: string) => { styles++; return color + text; }, bold: (text: string) => text, strikethrough: (text: string) => text };
	const tui = { terminal: { rows: 60 }, requestRender() {} };
	const pi = fakePi();
	const ctx = Object.assign(fakeCtx(base, "layout-test"), {
		hasUI: true,
		ui: { theme, notify() {}, setWidget(_key: string, factory?: (tui: unknown, theme: unknown) => Widget) { widget?.dispose?.(); widget = factory?.(tui, theme); } },
	});
	try {
		const { default: taskPanel } = await import("../extensions/task-panel.js");
		taskPanel(pi as never);
		const tool = pi.tools.get("tasks_write");
		const write = (params: unknown) => tool.execute("layout", params, undefined, undefined, ctx);
		const result = await write({ action: "replace", tasks: [{ content: "First", status: "pending" }, { content: "Chosen", status: "in_progress", phase: "Build", notes: ["original"] }], panel: "expanded" });
		expect(result.details.state.tasks.map((task: { status: string }) => task.status)).toEqual(["pending", "in_progress"]);
		await write({ action: "set_panel", panel: "expanded" });
		const first = widget!.render(80);
		const count = styles;
		expect(widget!.render(80)).toEqual(first);
		expect(styles).toBe(count);
		widget!.render(40);
		expect(styles).toBeGreaterThan(count);
		const narrowCount = styles;
		tui.terminal.rows = 12;
		expect(widget!.render(40).length).toBeLessThanOrEqual(4);
		expect(styles).toBeGreaterThan(narrowCount);
		color = "new-theme ";
		widget!.invalidate();
		expect(widget!.render(40).join("\n")).toContain("new-theme");
		tui.terminal.rows = 60;
		await write({ action: "append_note", task: "Chosen", note: "updated" });
		expect(widget!.render(80).join("\n")).toContain("updated");
		await write({ action: "mark_done", task: "Chosen" });
		expect(widget!.render(80).join("\n")).not.toContain("note: updated");
		writeFileSync(join(base, "tasks.md"), "# Tasks\n- Import first\n- Import chosen (active)\n  note: imported\n");
		await pi.commands.get("tasks").handler("import tasks.md", ctx);
		const imported = pi.appended.at(-1)!.data;
		expect(imported.tasks.map((task: { status: string }) => task.status)).toEqual(["pending", "in_progress"]);
		expect(widget!.render(80).join("\n")).toContain("imported");
		writeFileSync(join(base, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-task-panel": { showNotesInExpanded: false }, "@vanillagreen/pi-tool-renderer": { globalGlyphStyleOverride: "ascii" } } } } }));
		clearPackageConfigCache();
		const restyled = widget!.render(80).join("\n");
		expect(restyled).not.toContain("note: imported");
		expect(restyled).toContain("+");
		expect(restyled).not.toContain("┏");
		await write({ action: "set_panel", panel: "hidden" });
		expect(widget).toBeUndefined();
		await write({ action: "replace", tasks: [] });
		expect(widget).toBeUndefined();
	} finally {
		await pi.handlers.get("session_shutdown")?.({}, ctx);
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previous;
		clearPackageConfigCache();
		if (previousRegistry === undefined) delete globals[registry];
		else globals[registry] = previousRegistry;
		rmSync(base, { recursive: true, force: true });
	}
});
