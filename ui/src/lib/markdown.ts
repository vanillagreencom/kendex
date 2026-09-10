import { Marked, type Tokens } from "marked";
import { highlightCode } from "@/lib/highlight";

// Catalog content is adversarial input: a SKILL.md a person previews here
// was written by whoever published the catalog, not by kendex. marked
// passes raw HTML straight through by default and only percent-encodes
// link/image URLs (it does not reject `javascript:`), so both paths are
// overridden to keep the preview inert — no injected markup, no clickable
// script URLs.
function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

const SAFE_HREF = /^(https?:|mailto:|#|\.?\/)/i;
function safeHref(href: string): string | null {
  return SAFE_HREF.test(href.trim()) ? href : null;
}

function html({ text }: Tokens.HTML | Tokens.Tag): string {
  return escapeHtml(text);
}

// An image is a network request to wherever its URL points, made the
// moment the preview renders — a readme's author gets to watch who
// opened it. No image loads; the alt text stands in.
function image({ text }: Tokens.Image): string {
  return `<span class="md-image">${escapeHtml(text || "image")}</span>`;
}

// `text` here is the fence's raw, unescaped source — exactly what
// highlightCode expects. highlight.js tokenizes it as plain text and
// re-escapes what it emits, so a fenced `<script>` still can't inject.
function code({ text, lang }: Tokens.Code): string {
  const requested = lang?.trim().split(/\s+/)[0]?.toLowerCase() || null;
  const { html, language } = highlightCode(text, requested);
  const cls = language ? `hljs language-${language}` : "hljs";
  return `<pre><code class="${cls}">${html}</code></pre>\n`;
}

const renderer = new Marked({ gfm: true });
renderer.use({
  renderer: {
    html,
    image,
    code,
    link({ href, title, tokens }: Tokens.Link): string {
      const text = this.parser.parseInline(tokens);
      const safe = safeHref(href);
      if (!safe) return text;
      const titleAttr = title ? ` title="${escapeHtml(title)}"` : "";
      return `<a href="${escapeHtml(safe)}"${titleAttr} rel="noopener noreferrer">${text}</a>`;
    },
  },
});

// The same hardening, with one policy changed: prose kendex draws inside
// its own layout carries no link at all. A document is previewed in a
// panel that swallows link clicks; a description sits in a row, a header
// and a hover card, where an anchor would move the app's own window and
// where nobody is looking to navigate from. The author's words survive
// either way — this is the branch an unsafe URL already takes.
const inlineRenderer = new Marked({ gfm: true });
inlineRenderer.use({
  renderer: {
    html,
    image,
    code,
    link({ tokens }: Tokens.Link): string {
      return this.parser.parseInline(tokens);
    },
  },
});

export function renderMarkdown(source: string): string {
  return renderer.parse(source, { async: false }) as string;
}

/** One line's worth: emphasis and `code`, but no blocks and no links. For
 *  prose kendex shows inside its own layout — a package description —
 *  where a heading or a list would break the surface it sits in and an
 *  anchor would offer a reader somewhere to go from a place nobody
 *  navigates from. A link's text is kept and drawn as text. Hardened by
 *  the same overrides as the full document. */
export function renderInlineMarkdown(source: string): string {
  return inlineRenderer.parseInline(source, { async: false }) as string;
}

// SKILL.md and agent files open with a YAML frontmatter block that the
// preview's own header already surfaces as name/description — left in, it
// renders as a stray "---" rule followed by raw "key: value" text instead
// of prose.
const FRONTMATTER = /^---\r?\n[\s\S]*?\r?\n---\r?\n?/;

export function stripFrontmatter(source: string): string {
  return source.replace(FRONTMATTER, "");
}
