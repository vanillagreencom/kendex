import { expect, test } from "bun:test";
import { buildSessionTree } from "../extensions/tree.ts";
import type { SessionInfo } from "../extensions/types.ts";

function session(path: string, modified: string, parentSessionPath?: string): SessionInfo {
	return { path, parentSessionPath, modified: new Date(modified) } as SessionInfo;
}

for (const row of [
	{
		name: "roots sort by latest activity anywhere in each subtree",
		sessions: [
			session("/older-root.jsonl", "2026-01-01T00:00:00Z"),
			session("/recent-child.jsonl", "2026-03-01T00:00:00Z", "/older-root.jsonl"),
			session("/newer-root.jsonl", "2026-02-01T00:00:00Z"),
		],
		children: false,
		expected: ["/older-root.jsonl", "/newer-root.jsonl"],
	},
	{
		name: "siblings sort by latest descendant activity",
		sessions: [
			session("/root.jsonl", "2026-01-01T00:00:00Z"),
			session("/older-child.jsonl", "2026-01-02T00:00:00Z", "/root.jsonl"),
			session("/recent-grandchild.jsonl", "2026-04-01T00:00:00Z", "/older-child.jsonl"),
			session("/newer-child.jsonl", "2026-03-01T00:00:00Z", "/root.jsonl"),
		],
		children: true,
		expected: ["/older-child.jsonl", "/newer-child.jsonl"],
	},
]) {
	test(row.name, () => {
		const roots = buildSessionTree(row.sessions);
		const nodes = row.children ? roots[0]?.children : roots;
		expect(nodes?.map((node) => node.session.path)).toEqual(row.expected);
	});
}
