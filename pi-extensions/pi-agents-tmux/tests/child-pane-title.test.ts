import { afterEach, describe, expect, test } from "bun:test";
import { createHarness, fakeCtx, type Harness, installExtension, teardown, withoutRealIntervals } from "./extension-fixture.js";

let currentHarness: Harness | undefined;

afterEach(() => {
	if (currentHarness) {
		teardown(currentHarness);
		currentHarness = undefined;
	}
});

describe("child pane title ownership", () => {
	test("bg one-shot child identity with inherited TMUX_PANE does not set the tmux pane title", async () => {
		currentHarness = createHarness({ childAgent: "reviewer-security", tmuxPane: "%parent" });
		const onSessionStart = await installExtension(currentHarness);
		await withoutRealIntervals(async () => {
			await onSessionStart({}, fakeCtx(currentHarness!));
		});
		expect(currentHarness.titleSpawnCalls).toHaveLength(0);
		expect(currentHarness.titles).toHaveLength(0);
	});

	test("visible pane child marker sets the tmux pane title", async () => {
		currentHarness = createHarness({ childAgent: "rust", childPane: "1", tmuxPane: "%42" });
		const onSessionStart = await installExtension(currentHarness);
		await withoutRealIntervals(async () => {
			await onSessionStart({}, fakeCtx(currentHarness!));
		});
		expect(currentHarness.titles).toContain("pi agent - rust");
		expect(currentHarness.titleSpawnCalls).toContainEqual({
			command: "tmux",
			args: ["select-pane", "-t", "%42", "-T", "agent:rust"],
		});
	});
});
