import { afterAll, mock } from "bun:test";
import { readdirSync } from "node:fs";
import { tmpdir } from "node:os";

// VST-199 leak guard: tempdirs this suite creates must be torn down by the
// test file that created them. Prefixes owned by this suite fail the run
// outright when left behind; unrelated system churn gets a generous tolerance.
const OWNED_TMP_PREFIXES = [
	"delegate-subagent-runtime-",
	"needs-completion-",
	"pi-agents-",
	"pi-subagent-",
	"rate-limit-scope-",
	"subagent-",
];
const UNRELATED_NEW_ENTRY_TOLERANCE = 64;
const tmpEntriesBeforeRun = new Set(readdirSync(tmpdir()));

afterAll(() => {
	const newEntries = readdirSync(tmpdir()).filter((name) => !tmpEntriesBeforeRun.has(name));
	const leaked = newEntries.filter((name) => OWNED_TMP_PREFIXES.some((prefix) => name.startsWith(prefix)));
	if (leaked.length > 0) {
		throw new Error(
			`pi-agents-tmux tests leaked ${leaked.length} tmp dir(s) (VST-199); add teardown in the creating test file: ${leaked.slice(0, 12).join(", ")}`,
		);
	}
	if (newEntries.length > UNRELATED_NEW_ENTRY_TOLERANCE) {
		throw new Error(
			`pi-agents-tmux test run left ${newEntries.length} new entries in ${tmpdir()} (tolerance ${UNRELATED_NEW_ENTRY_TOLERANCE}); check for an untracked tempdir prefix (VST-199)`,
		);
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
