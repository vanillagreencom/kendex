import { useEffect, useState } from "react";
import { commands, type ItemKind, type Scope } from "@/bindings";
import { FilePane } from "@/components/files/file-pane";
import { StatusNote } from "@/components/status-note";
import { Skeleton } from "@/components/ui/skeleton";
import { FILE_READ_FAILED_TITLE, NO_README_NOTE } from "@/lib/copy-files";

type ReadmeState =
  | { status: "loading" }
  | { status: "none" }
  | { status: "error"; error: string }
  | { status: "ok"; path: string; content: string; truncated: boolean };

/** The package's own words about itself, and nothing else.
 *
 *  The Overview is the README, so a package that carries none says so.
 *  Falling back to whichever file happens to be first would put an
 *  arbitrary source file under the package's details, where a reader would
 *  take it for the package describing itself. Its files are a tab of their
 *  own, where picking one is the reader's own act. */
export function PackageReadme({
  scope,
  kind,
  name,
}: {
  scope: Scope;
  kind: ItemKind;
  name: string;
}) {
  const [state, setState] = useState<ReadmeState>({ status: "loading" });

  useEffect(() => {
    let cancelled = false;
    setState({ status: "loading" });
    void commands.packageReadme(scope, kind, name).then((response) => {
      if (cancelled) return;
      setState(
        response.status === "error"
          ? { status: "error", error: response.error }
          : response.data === null
            ? { status: "none" }
            : { status: "ok", ...response.data },
      );
    });
    return () => {
      cancelled = true;
    };
  }, [scope, kind, name]);

  if (state.status === "loading") {
    return (
      <div className="space-y-2">
        <Skeleton className="h-3.5 w-3/4" />
        <Skeleton className="h-3.5 w-full" />
        <Skeleton className="h-3.5 w-5/6" />
      </div>
    );
  }
  if (state.status === "none") {
    return <p className="text-sm text-muted-foreground">{NO_README_NOTE}</p>;
  }
  if (state.status === "error") {
    return (
      <StatusNote tone="critical" title={FILE_READ_FAILED_TITLE}>
        {state.error}
      </StatusNote>
    );
  }
  return <FilePane {...state} />;
}
