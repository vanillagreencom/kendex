import { renderMarkdown, stripFrontmatter } from "@/lib/markdown";

/** Untrusted markdown, rendered hardened: raw HTML escaped, unsafe link and
 *  image URLs stripped (see lib/markdown.ts), and link clicks swallowed — a
 *  preview link that navigated the app window would be worse than no link
 *  at all. */
export function MarkdownView({ source }: { source: string }) {
  return (
    // This is a click guard on rendered content, not an interactive
    // control, so it has no keyboard equivalent to wire up.
    // biome-ignore lint/a11y/noStaticElementInteractions: swallows clicks bubbling from links inside untrusted rendered markdown, not a widget
    // biome-ignore lint/a11y/useKeyWithClickEvents: same — nothing here to reach by keyboard
    <div
      className="prose-preview max-w-none text-sm"
      onClick={(event) => {
        if ((event.target as HTMLElement).closest("a")) event.preventDefault();
      }}
      // biome-ignore lint/security/noDangerouslySetInnerHtml: renderMarkdown escapes raw HTML tags and unsafe link/image URLs, and highlights fenced code from plain text, before this ever runs
      dangerouslySetInnerHTML={{
        __html: renderMarkdown(stripFrontmatter(source)),
      }}
    />
  );
}
