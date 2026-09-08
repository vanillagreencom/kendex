import assert from "node:assert/strict";
import test from "node:test";
import { clearMemoryForTests, getWebContent, restoreStoredContent, storeWebContent } from "../src/storage.js";

test("stored content can be restored from session custom entries", (t) => {
	clearMemoryForTests();
	t.after(clearMemoryForTests);
	const appended: any[] = [];
	const pi = { appendEntry(type: string, data: unknown) { appended.push({ type, data }); } } as any;
	const stored = storeWebContent(pi, { title: "T", url: "https://example.com", content: "Body" });
	const contentBeforeRestore = getWebContent(stored.id)?.content;
	clearMemoryForTests();
	restoreStoredContent({ sessionManager: { getEntries: () => appended.map((entry) => ({ type: "custom", customType: entry.type, data: entry.data })) } } as any);
	assert.deepEqual({ contentBeforeRestore, urlAfterRestore: getWebContent(stored.id)?.url }, { contentBeforeRestore: "Body", urlAfterRestore: "https://example.com" });
});
