import { mock } from "bun:test";

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
