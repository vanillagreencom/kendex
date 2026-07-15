import { canonicalPath } from "./paths.js";
import type { FlatSessionNode, SessionInfo, SessionTreeNode } from "./types.js";

export function buildSessionTree(sessions: SessionInfo[]): SessionTreeNode[] {
	const byPath = new Map<string, SessionTreeNode>();
	for (const session of sessions) {
		const key = canonicalPath(session.path) ?? session.path;
		byPath.set(key, { session, children: [] });
	}

	const roots: SessionTreeNode[] = [];
	for (const session of sessions) {
		const key = canonicalPath(session.path) ?? session.path;
		const node = byPath.get(key)!;
		const parent = canonicalPath(session.parentSessionPath);
		if (parent && byPath.has(parent)) byPath.get(parent)!.children.push(node);
		else roots.push(node);
	}

	const latestActivity = new Map<SessionTreeNode, number>();
	const updateLatestActivity = (node: SessionTreeNode): number => {
		let latest = node.session.modified.getTime();
		for (const child of node.children) latest = Math.max(latest, updateLatestActivity(child));
		latestActivity.set(node, latest);
		return latest;
	};
	for (const root of roots) updateLatestActivity(root);

	const sortNodes = (nodes: SessionTreeNode[]) => {
		nodes.sort((a, b) => (latestActivity.get(b) ?? 0) - (latestActivity.get(a) ?? 0));
		for (const node of nodes) sortNodes(node.children);
	};
	sortNodes(roots);
	return roots;
}

export function flattenSessionTree(roots: SessionTreeNode[]): FlatSessionNode[] {
	const result: FlatSessionNode[] = [];
	const walk = (node: SessionTreeNode, depth: number, ancestorContinues: boolean[], isLast: boolean) => {
		result.push({ session: node.session, depth, isLast, ancestorContinues, score: 0 });
		for (let i = 0; i < node.children.length; i++) {
			const childIsLast = i === node.children.length - 1;
			const continues = depth > 0 ? !isLast : false;
			walk(node.children[i]!, depth + 1, [...ancestorContinues, continues], childIsLast);
		}
	};
	for (let i = 0; i < roots.length; i++) walk(roots[i]!, 0, [], i === roots.length - 1);
	return result;
}

export function rowTreePrefix(node: FlatSessionNode): string {
	if (node.depth === 0) return "";
	const parts = node.ancestorContinues.map((continues) => (continues ? "│  " : "   "));
	return parts.join("") + (node.isLast ? "└─ " : "├─ ");
}
