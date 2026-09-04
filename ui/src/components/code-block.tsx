import { highlightCode, languageFromPath } from "@/lib/highlight";

// highlight.js tokenizes `content` as plain text and re-escapes what it
// emits — it never interprets the file's own bytes as markup — so this is
// as safe as a plain <pre><code>{content}</code>.
export function CodeBlock({
  path,
  content,
}: {
  path: string;
  content: string;
}) {
  const { html, language } = highlightCode(content, languageFromPath(path));
  const cls = language ? `hljs language-${language}` : "hljs";
  return (
    <pre className="overflow-x-auto font-mono text-xs">
      {/* biome-ignore lint/security/noDangerouslySetInnerHtml: highlightCode escapes every character it emits (see highlight.ts) */}
      <code className={cls} dangerouslySetInnerHTML={{ __html: html }} />
    </pre>
  );
}
