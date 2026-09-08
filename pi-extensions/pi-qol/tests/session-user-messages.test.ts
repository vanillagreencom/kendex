import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sessionUserMessages } from "../extensions/qol/session-search/cache.ts";

test("session user messages retain prompt text and timestamp", () => {
	const root = mkdtempSync(join(tmpdir(), "pi-qol-user-messages-"));
	try {
		expect.hasAssertions();
		const path = join(root, "session.jsonl");
		writeFileSync(path, [
			JSON.stringify({ type: "message", timestamp: "2026-06-04T00:00:00.000Z", message: { role: "user", content: [{ type: "text", text: "first prompt" }] } }),
			JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "answer" }] } }),
			JSON.stringify({ type: "message", message: { role: "user", content: [{ type: "image" }, { type: "text", text: "second prompt" }] } }),
		].join("\n"));

		const messages = sessionUserMessages(path);
		expect({ texts: messages.map((message) => message.text), timestamp: messages[0]?.timestamp }).toEqual({
			texts: ["first prompt", "[image] second prompt"],
			timestamp: new Date("2026-06-04T00:00:00.000Z").getTime(),
		});
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});
