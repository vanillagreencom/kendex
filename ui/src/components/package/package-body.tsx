import type {
  ObservedItem,
  PackageDiff,
  PackageFile,
  PackageMeta_Serialize,
  VersionRow,
} from "@/bindings";
import { DiffView } from "@/components/diff/diff-view";
import { DotSpinner } from "@/components/loading";
import { FilePreview } from "@/components/package/file-preview";
import { EditedNotice } from "@/components/package/fork-notice";
import { PackageSidebar } from "@/components/package/package-sidebar";
import type { PackageView } from "@/components/package/use-package-data";
import type { ItemGroup } from "@/lib/derive";
import { harnessName } from "@/lib/labels";
import { versionRowLabel } from "@/lib/versions";
import type { PackageRef } from "@/stores/nav";

/** What a package is, as installed: its provenance and switches on the
 *  left, with the file it is made of — or a comparison — on the right. The
 *  safety reading answers for the whole package rather than for what this
 *  view happens to show, so it has a tab of its own. */
export function PackageBody({
  reference,
  group,
  primary,
  meta,
  versions,
  files,
  filesNote,
  installed,
  view,
  setView,
  diff,
  busy,
  reading,
  onToggle,
  onSwitchVersion,
  onCompare,
  onFollow,
  onReload,
}: {
  reference: PackageRef;
  group: ItemGroup;
  primary: ObservedItem;
  meta: PackageMeta_Serialize | null;
  versions: VersionRow[];
  files: PackageFile[];
  /** Why the file list has no files, where its read did not land. */
  filesNote: string | null;
  installed: VersionRow | undefined;
  view: PackageView;
  setView: (view: PackageView) => void;
  diff: PackageDiff | null;
  busy: boolean;
  /** Whether the page's own reads are out. */
  reading: boolean;
  onToggle: (enable: boolean) => void;
  onSwitchVersion: (row: VersionRow) => void;
  onCompare: (row: VersionRow) => void;
  onFollow: () => void;
  onReload: () => void;
}) {
  return (
    <>
      <EditedNotice
        scope={reference.scope}
        kind={reference.kind}
        name={reference.name}
        alreadyForked={meta?.fork != null}
        onViewChanges={(harness) => {
          if (!installed) return;
          setView({
            mode: "diff",
            from: installed.id,
            to: "installed",
            fromLabel: versionRowLabel(installed),
            toLabel: harness
              ? `your edits in ${harnessName(harness)}`
              : "your edits",
            harness,
          });
        }}
        onResolved={onReload}
      />
      <div className="flex flex-col gap-8">
        {view.mode === "diff" ? (
          diff ? (
            <DiffView
              diff={diff}
              fromLabel={view.fromLabel}
              toLabel={view.toLabel}
              onClose={() => setView({ mode: "files", file: null })}
            />
          ) : (
            <p className="flex items-center gap-2 text-sm text-muted-foreground">
              <DotSpinner />
              Comparing…
            </p>
          )
        ) : (
          <div className="flex flex-col gap-8 lg:flex-row">
            <PackageSidebar
              group={group}
              primary={primary}
              meta={meta}
              versions={versions}
              files={files}
              filesNote={filesNote}
              selectedFile={view.file}
              busy={busy}
              retryRunning={reading}
              onToggle={(_, enable) => onToggle(enable)}
              onSwitchVersion={onSwitchVersion}
              onCompare={onCompare}
              onFollow={onFollow}
              onSelectFile={(file) => setView({ mode: "files", file })}
              onRetryFiles={onReload}
            />
            <div className="min-w-0 flex-1">
              <FilePreview
                scope={reference.scope}
                kind={reference.kind}
                name={reference.name}
                path={view.file}
              />
            </div>
          </div>
        )}
      </div>
    </>
  );
}
