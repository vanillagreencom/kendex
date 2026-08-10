import { afterAll, mock } from "bun:test";
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Leak guard: every tempdir this suite creates must be torn down by the test
// file that created it. The whole run gets its OWN tmp root (os.tmpdir()
// re-reads TMPDIR per call, and this preload runs before any test module),
// so concurrent pi-agents-tmux runs can never flag each other's live dirs,
// unrelated system churn is invisible, and the final sweep removes the root
// wholesale after reporting. A short settle pass absorbs writes that land
// during shutdown so a just-recreated dir is measured at rest.
const RUN_TMP_ROOT = mkdtempSync(join(tmpdir(), "pi-agents-tmux-run-"));
process.env.TMPDIR = RUN_TMP_ROOT;

afterAll(async () => {
	let entries = readdirSync(RUN_TMP_ROOT);
	for (let i = 0; i < 10; i += 1) {
		await new Promise((resolve) => setTimeout(resolve, 30));
		const next = readdirSync(RUN_TMP_ROOT);
		if (next.length === entries.length && next.every((name, idx) => name === entries[idx])) break;
		entries = next;
	}
	try {
		if (entries.length > 0) {
			throw new Error(
				`pi-agents-tmux tests leaked ${entries.length} tmp dir(s); add teardown in the creating test file: ${entries.slice(0, 12).join(", ")}`,
			);
		}
	} finally {
		rmSync(RUN_TMP_ROOT, { force: true, recursive: true });
	}
});

// Minimal typebox surface used by extensions/subagent/tools.ts; typebox is an
// uninstalled peer dependency in this checkout, mocked like the pi peers below.
mock.module("typebox", () => {
	const withOptions = (schema: Record<string, unknown>, options?: Record<string, unknown>) => ({
		...(options ?? {}),
		...schema,
	});
	return {
		Type: {
			Array: (items: unknown, options?: Record<string, unknown>) => withOptions({ items, type: "array" }, options),
			Boolean: (options?: Record<string, unknown>) => withOptions({ type: "boolean" }, options),
			Number: (options?: Record<string, unknown>) => withOptions({ type: "number" }, options),
			Object: (properties: Record<string, unknown>, options?: Record<string, unknown>) =>
				withOptions({ properties, type: "object" }, options),
			Optional: (schema: Record<string, unknown>) => ({ ...schema }),
			String: (options?: Record<string, unknown>) => withOptions({ type: "string" }, options),
		},
	};
});

mock.module("@earendil-works/pi-coding-agent", () => {
	const truncate = (text: string, limits: { maxBytes: number; maxLines: number }, fromTail = false) => {
		const lines = text.split(/\r?\n/);
		const selectedLines = fromTail ? lines.slice(-limits.maxLines) : lines.slice(0, limits.maxLines);
		let content = selectedLines.join("\n");
		if (Buffer.byteLength(content) > limits.maxBytes) content = content.slice(0, limits.maxBytes);
		return {
			content,
			outputBytes: Buffer.byteLength(content),
			outputLines: selectedLines.length,
			totalBytes: Buffer.byteLength(text),
			totalLines: lines.length,
			truncated: content !== text,
		};
	};
	return {
		formatSize(bytes: number) {
			return `${bytes} B`;
		},
		getAgentDir() {
			return process.env.PI_CODING_AGENT_DIR ?? "/tmp/pi-agent-test";
		},
		getMarkdownTheme() {
			return {};
		},
		parseFrontmatter(content: string) {
			const match = content.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
			if (!match) return { frontmatter: {}, body: content };
			const frontmatter: Record<string, unknown> = {};
			for (const line of match[1].split(/\r?\n/)) {
				const separator = line.indexOf(":");
				if (separator < 0) continue;
				frontmatter[line.slice(0, separator).trim()] = line.slice(separator + 1).trim();
			}
			return { frontmatter, body: match[2] };
		},
		truncateHead(text: string, limits: { maxBytes: number; maxLines: number }) {
			return truncate(text, limits, false);
		},
		truncateTail(text: string, limits: { maxBytes: number; maxLines: number }) {
			return truncate(text, limits, true);
		},
		async withFileMutationQueue<T>(_filePath: string, fn: () => Promise<T>): Promise<T> {
			return fn();
		},
	};
});

mock.module("@earendil-works/pi-tui", () => {
	class Container {
		children: unknown[] = [];
		addChild(child: unknown) { this.children.push(child); }
		render() { return []; }
	}
	class Spacer {
		render() { return [""]; }
	}
	return {
		Container,
		Markdown: Container,
		matchesKey() {
			return false;
		},
		Spacer,
		truncateToWidth(text: string, width: number, suffix = "") {
			return text.length > width ? `${text.slice(0, Math.max(0, width - suffix.length))}${suffix}` : text;
		},
		visibleWidth(text: string) {
			return text.replace(/\x1b\[[0-9;]*m/g, "").length;
		},
		wrapTextWithAnsi(text: string, _width: number) {
			return text.split(/\r?\n/);
		},
	};
});

mock.module("@earendil-works/pi-ai", () => ({
	StringEnum(values: readonly string[], options?: Record<string, unknown>) {
		return { ...options, enum: values, type: "string" };
	},
}));
