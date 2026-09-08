import { afterEach, expect, mock, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { sessionFixture } from "./lib/session-fixture.ts";

mock.module("@earendil-works/pi-tui", () => ({
	truncateToWidth: (text: string, width: number) => text.slice(0, width),
	visibleWidth: (text: string) => text.replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))/g, "").length,
}));

afterEach(async () => {
	const { sessionUserMessagesCache } = await import("../extensions/session-data.ts");
	sessionUserMessagesCache.clear();
});

test("session user messages select user text, image markers and timestamps", async () => {
	const { userMessagesForSession } = await import("../extensions/session-data.ts");
	const dir = sessionFixture();
	const path = join(dir, "session.jsonl");
	writeFileSync(path, [
		JSON.stringify({ type: "message", timestamp: "2026-06-04T00:00:00.000Z", message: { role: "user", content: [{ type: "text", text: "first prompt" }] } }),
		JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "answer" }] } }),
		JSON.stringify({ type: "message", message: { role: "user", content: [{ type: "image" }, { type: "text", text: "second prompt" }] } }),
	].join("\n"));

	const messages = userMessagesForSession({ path, firstMessage: "", name: "" } as never);
	expect(messages.map((message) => message.text)).toEqual(["first prompt", "[image] second prompt"]);
	expect(messages[0]?.timestamp).toBe(new Date("2026-06-04T00:00:00.000Z").getTime());
});
