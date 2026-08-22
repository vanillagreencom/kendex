import type {
  ObservedItem,
  PackageDiff,
  PackageFile,
  PackageMeta_Serialize,
  UpdateRow,
  VersionRow,
} from "@/bindings";
import { DiffView } from "@/components/diff/diff-view";
import { DotSpinner } from "@/components/loading";
import { FilePreview } from "@/components/package/file-preview";
import { EditedNotice } from "@/components/package/fork-notice";
import { PackageSidebar } from "@/components/package/package-sidebar";
import type { PackageView } from "@/components/package/use-package-data";
import { NO_COMPARISON_BODY, NO_COMPARISON_TITLE } from "@/lib/copy";
import type { ItemGroup } from "@/lib/derive";
import { harnessName } from "@/lib/labels";
import { versionRowLabel } from "@/lib/versions";
import type { PackageRef } from "@/stores/nav";
import { useProblemsStore } from "@/stores/problems";

/** What a package is, as installed: its provenance and switches on the
 *  left, the file it is made of — or a comparison — on the right. */
export function PackageBody({
  reference,
  group,
  primary,
  meta,
  editedRow,
  versions,
  files,
  installed,
  view,
  setView,
  diff,
  busy,
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
  /** This page's own place's update row, when its files were edited by
   *  hand — from the same join the header's badges read, so the page
   *  cannot say two things about one place. */
  editedRow: UpdateRow | null;
  versions: VersionRow[];
  files: PackageFile[];
  installed: VersionRow | undefined;
  view: PackageView;
  setView: (view: PackageView) => void;
  diff: PackageDiff | null;
  busy: boolean;
  onToggle: (enable: boolean) => void;
  onSwitchVersion: (row: VersionRow) => void;
  onCompare: (row: VersionRow) => void;
  onFollow: () => void;
  onReload: () => void;
}) {
  return (
    <>
      <EditedNotice
        row={editedRow}
        onViewChanges={(harness) => {
          // A click that does nothing and says nothing is the failure this
          // notice exists to prevent, so the one case that cannot open a
          // comparison explains itself instead.
          if (!installed) {
            useProblemsStore.getState().showError({
              title: NO_COMPARISON_TITLE,
              message: NO_COMPARISON_BODY,
            });
            return;
          }
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
            selectedFile={view.file}
            busy={busy}
            onToggle={(_, enable) => onToggle(enable)}
            onSwitchVersion={onSwitchVersion}
            onCompare={onCompare}
            onFollow={onFollow}
            onSelectFile={(file) => setView({ mode: "files", file })}
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
    </>
  );
}
