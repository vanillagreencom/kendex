import { expect, test } from "bun:test";
import { buildSessionTree } from "../extensions/tree.ts";

function session(path: string, modified: string, parentSessionPath?: string) {
	return {
		path,
		parentSessionPath,
		modified: new Date(modified),
	} as any;
}

test("session trees sort roots by latest activity anywhere in each subtree", () => {
	const roots = buildSessionTree([
		session("/older-root.jsonl", "2026-01-01T00:00:00Z"),
		session("/recent-child.jsonl", "2026-03-01T00:00:00Z", "/older-root.jsonl"),
		session("/newer-root.jsonl", "2026-02-01T00:00:00Z"),
	]);

	expect(roots.map((node) => node.session.path)).toEqual(["/older-root.jsonl", "/newer-root.jsonl"]);
});

test("session trees sort siblings by latest descendant activity", () => {
	const roots = buildSessionTree([
		session("/root.jsonl", "2026-01-01T00:00:00Z"),
		session("/older-child.jsonl", "2026-01-02T00:00:00Z", "/root.jsonl"),
		session("/recent-grandchild.jsonl", "2026-04-01T00:00:00Z", "/older-child.jsonl"),
		session("/newer-child.jsonl", "2026-03-01T00:00:00Z", "/root.jsonl"),
	]);

	expect(roots[0]?.children.map((node) => node.session.path)).toEqual(["/older-child.jsonl", "/newer-child.jsonl"]);
});