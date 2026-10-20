import { afterAll, beforeAll, expect, test } from "bun:test";
import { initTheme, ToolExecutionComponent } from "@earendil-works/pi-coding-agent";
import { stripAnsi } from "../tool-renderer/ansi.js";
import { installToolExecutionRendererPatch } from "../tool-renderer/chrome.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
const shutdown: Array<() => void> = [];
const ui = { requestRender() {} };
const result = { content: [{ type: "text", text: "ok" }], isError: false };

beforeAll(() => {
	initTheme("dark", false);
	installToolExecutionRendererPatch({ on: (event: string, handler: () => void) => event === "session_shutdown" && shutdown.push(handler) } as any);
});

afterAll(() => {
	for (const handler of shutdown.splice(0)) handler();
});

/** A block for a tool this session does not register, as Pi builds it. */
function unknownBlock(args: Record<string, unknown>) {
	return new ToolExecutionComponent("workflow_result", "call-1", args, {}, undefined, ui as any, world().cwd);
}

function rows(block: ToolExecutionComponent): string[] {
	return block.render(80).map(stripAnsi).filter((line) => !/^─+$/.test(line));
}

test("a restored block draws one result row with the label once", () => {
	// Pi's session restore sets the recorded result and never marks execution started.
	const block = unknownBlock({ result: "all done" });
	block.updateResult(result as any);
	expect(rows(block)).toEqual(["● Workflow Result · done · ctrl+o to expand"]);
});

test("a live call draws its call row before execution starts", () => {
	const block = unknownBlock({ result: "all" });
	expect(rows(block)).toEqual(["● Workflow Result"]);
	block.setArgsComplete();
	expect(rows(block)).toEqual(["● Workflow Result"]);
});

test("a block whose execution started draws only its result row", () => {
	const block = unknownBlock({ result: "all" });
	block.markExecutionStarted();
	expect(rows(block)).toEqual([]);
	block.updateResult(result as any);
	expect(rows(block)).toEqual(["● Workflow Result · done · ctrl+o to expand"]);
});

test("a recognised argument still follows the label", () => {
	const block = unknownBlock({ path: "notes.md" });
	expect(rows(block)).toEqual(["● Workflow Result notes.md"]);
	block.updateResult(result as any);
	expect(rows(block)).toEqual(["● Workflow Result notes.md · done · ctrl+o to expand"]);
});
