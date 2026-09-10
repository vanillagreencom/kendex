import { renderInlineMarkdown } from "@/lib/markdown";
import { cn } from "@/lib/utils";

/** A description as its author wrote it: `code` for the file names and
 *  commands, emphasis where they meant emphasis. Same hardened overrides
 *  as the file preview — descriptions come from catalogs, not from us —
 *  with links rendered as their own text, since a description is not a
 *  place anyone expects to navigate from and an anchor here would move the
 *  app's own window. `renderInlineMarkdown` holds that, so every surface
 *  drawing a description gets it without a handler of its own. */
export function InlineMarkdown({
  source,
  className,
}: {
  source: string;
  className?: string;
}) {
  return (
    <span
      className={cn("prose-inline", className)}
      // biome-ignore lint/security/noDangerouslySetInnerHtml: renderInlineMarkdown escapes raw HTML and unsafe URLs before this runs
      dangerouslySetInnerHTML={{ __html: renderInlineMarkdown(source) }}
    />
  );
}
