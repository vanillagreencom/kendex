import { Copy } from "lucide-react";
import { toast } from "sonner";
import { CodeBlock } from "@/components/code-block";
import { MarkdownView } from "@/components/markdown-view";
import { Button } from "@/components/ui/button";
import { COPY_PATH_LABEL, PATH_COPIED_TOAST } from "@/lib/copy";
import { FILE_TRUNCATED_NOTE } from "@/lib/copy-files";

/** The app's one file preview: a bar naming the file, then the file —
 *  markdown lightly styled, everything else syntax-highlighted. Whatever
 *  the surface, a file looks the same and carries the same way to take its
 *  path away with you. */
export function FilePane({
  path,
  content,
  truncated,
}: {
  path: string;
  content: string;
  /** Only the head of the file was read; the bar says so rather than
   *  letting a prefix read as the whole. */
  truncated: boolean;
}) {
  const isMarkdown = path.toLowerCase().endsWith(".md");
  const basename = path.split("/").pop() ?? path;

  const copyPath = () => {
    void navigator.clipboard.writeText(path).then(() => {
      toast.success(PATH_COPIED_TOAST);
    });
  };

  return (
    <div className="overflow-hidden rounded-lg border bg-muted/20">
      <div className="sticky top-0 z-10 flex items-center justify-between gap-2 border-b bg-muted/60 px-3 py-1.5 backdrop-blur-sm">
        <span className="min-w-0 truncate font-mono text-xs text-muted-foreground">
          {basename}
        </span>
        <span className="flex shrink-0 items-center gap-2">
          {truncated ? (
            <span className="text-[11px] text-muted-foreground">
              {FILE_TRUNCATED_NOTE}
            </span>
          ) : null}
          <Button
            variant="ghost"
            size="icon-xs"
            aria-label={COPY_PATH_LABEL}
            title={COPY_PATH_LABEL}
            onClick={copyPath}
          >
            <Copy className="size-3.5" />
          </Button>
        </span>
      </div>
      <div className="p-3">
        {isMarkdown ? (
          <MarkdownView source={content} />
        ) : (
          <CodeBlock path={path} content={content} />
        )}
      </div>
    </div>
  );
}
