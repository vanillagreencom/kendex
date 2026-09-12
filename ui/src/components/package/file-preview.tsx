import { useEffect, useState } from "react";
import {
  commands,
  type ItemKind,
  type Scope,
  type SourceReadRefused,
} from "@/bindings";
import { FilePane } from "@/components/files/file-pane";
import { StatusNote } from "@/components/status-note";
import { Skeleton } from "@/components/ui/skeleton";
import { FILE_READ_FAILED_TITLE, NO_FILES_NOTE } from "@/lib/copy-files";
import { packageFileRefusalLine } from "@/lib/package-read-state";

type PreviewState =
  | { status: "loading" }
  | { status: "error"; error: SourceReadRefused | string }
  | { status: "ok"; path: string; content: string; truncated: boolean };

/** One file of an installed package, read and then drawn in the app's one
 *  file pane. `path` null means the readme, which is what a package opens
 *  on. */
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
              commands
                .packageFiles(scope, kind, name)
                .then((files) =>
                  files.status === "ok" && files.data[0]
                    ? commands.packageFile(
                        scope,
                        kind,
                        name,
                        files.data[0].path,
                      )
                    : files.status === "ok"
                      ? ({ status: "error", error: NO_FILES_NOTE } as const)
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
            ? { status: "error", error: NO_FILES_NOTE }
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

  // One slot, drawn as a failure: what can fail here is the one file. Why
  // the not-downloaded kind never reaches it, and is still read through
  // the judge, is `packageFileRefusalLine`'s.
  if (state.status === "error") {
    return (
      <StatusNote tone="critical" title={FILE_READ_FAILED_TITLE}>
        {packageFileRefusalLine(state.error)}
      </StatusNote>
    );
  }

  return <FilePane {...state} />;
}
