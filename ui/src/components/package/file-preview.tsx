import { Copy } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { commands, type ItemKind, type Scope } from "@/bindings";
import { CodeBlock } from "@/components/code-block";
import { MarkdownView } from "@/components/markdown-view";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";

type PreviewState =
  | { status: "loading" }
  | { status: "error"; error: string }
  | { status: "ok"; path: string; content: string; truncated: boolean };

/** The package page's right pane: one file of the package, rendered —
 *  markdown lightly styled, everything else syntax-highlighted. `path`
 *  null means the readme, which is what the page opens on. */
export function FilePreview({
  scope,
  kind,
  name,
  path,
}: {
  scope: Scope;
  kind: ItemKind;
  name: string;
  path: string | null;
}) {
  const [state, setState] = useState<PreviewState>({ status: "loading" });

  useEffect(() => {
    let cancelled = false;
    setState({ status: "loading" });
    const query = path
      ? commands.packageFile(scope, kind, name, path)
      : commands.packageReadme(scope, kind, name).then((response) =>
          response.status === "ok" && response.data === null
            ? // No readme: fall back to the package's primary file so the
              // pane is never empty on open.
              commands.packageFiles(scope, kind, name).then((files) =>
                files.status === "ok" && files.data[0]
                  ? commands.packageFile(scope, kind, name, files.data[0].path)
                  : files.status === "ok"
                    ? ({
                        status: "error",
                        error: "this package has no files",
                      } as const)
                    : files,
              )
            : response,
        );
    void query.then((response) => {
      if (cancelled) return;
      setState(
        response.status === "ok" && response.data
          ? { status: "ok", ...response.data }
          : response.status === "ok"
            ? { status: "error", error: "this package has no files" }
            : { status: "error", error: response.error },
      );
    });
    return () => {
      cancelled = true;
    };
  }, [scope, kind, name, path]);

  if (state.status === "loading") {
    return (
      <div className="space-y-2">
        <Skeleton className="h-3.5 w-3/4" />
        <Skeleton className="h-3.5 w-full" />
        <Skeleton className="h-3.5 w-5/6" />
        <Skeleton className="h-3.5 w-2/3" />
      </div>
    );
  }

  if (state.status === "error") {
    return (
      <StatusNote tone="critical" title="This file couldn't be shown">
        {state.error}
      </StatusNote>
    );
  }

  return <FileContent {...state} />;
}

/** One file, rendered — markdown lightly styled, everything else
 *  syntax-highlighted — under a bar naming it. */
export function FileContent({
  path,
  content,
  truncated,
}: {
  path: string;
  content: string;
  truncated: boolean;
}) {
  const isMarkdown = path.toLowerCase().endsWith(".md");
  const basename = path.split("/").pop() ?? path;

  const copyPath = () => {
    void navigator.clipboard.writeText(path).then(() => {
      toast.success("Path copied");
    });
  };

  return (
    <div className="rounded-lg border bg-muted/20">
      <div className="sticky top-0 z-10 flex items-center justify-between gap-2 rounded-t-lg border-b bg-muted/60 px-3 py-1.5 backdrop-blur-sm">
        <span className="min-w-0 truncate font-mono text-xs text-muted-foreground">
          {basename}
        </span>
        <span className="flex shrink-0 items-center gap-2">
          {truncated ? (
            <span className="text-[11px] text-muted-foreground">
              Showing first 64 KB
            </span>
          ) : null}
          <Button
            variant="ghost"
            size="icon-xs"
            aria-label="Copy path"
            title="Copy path"
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
