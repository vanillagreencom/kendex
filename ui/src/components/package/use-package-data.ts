import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import {
  commands,
  type HarnessId,
  type PackageDiff,
  type PackageFile,
  type PackageMeta_Serialize,
  type VersionRow,
} from "@/bindings";
import {
  FOLLOW_SOURCE_TOAST,
  updatedToastLabel,
  VERSION_ERROR_TITLE,
} from "@/lib/copy";
import { versionRowLabel } from "@/lib/versions";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import type { PackageRef } from "@/stores/nav";
import { useProblemsStore } from "@/stores/problems";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";

export type PackageView =
  | { mode: "files"; file: string | null }
  | {
      mode: "diff";
      from: string;
      to: string;
      fromLabel: string;
      toLabel: string;
      /** The rendering to read the installed side from, when the
       *  comparison is about one tool's edited copy rather than the
       *  package's primary installation. */
      harness?: HarnessId;
    };

/** Which rendering a diff reads: the one the view names, else the
 *  package's primary installation. */
export const diffHarness = (
  view: PackageView,
  primary: HarnessId | null,
): HarnessId | null =>
  view.mode === "diff" && view.harness ? view.harness : primary;

/** The package page's reads, refetchable as one unit after a mutation. */
export function usePackageData(ref: PackageRef | null) {
  const [meta, setMeta] = useState<PackageMeta_Serialize | null>(null);
  const [files, setFiles] = useState<PackageFile[]>([]);
  const [versions, setVersions] = useState<VersionRow[]>([]);

  const load = useCallback(() => {
    if (!ref) return;
    void commands
      .packageMeta(ref.scope, ref.kind, ref.name)
      .then((response) => {
        setMeta(response.status === "ok" ? response.data : null);
      });
    void commands
      .packageFiles(ref.scope, ref.kind, ref.name)
      .then((response) => {
        setFiles(response.status === "ok" ? response.data : []);
      });
    void commands
      .packageVersions(ref.scope, ref.kind, ref.name)
      .then((response) => {
        setVersions(response.status === "ok" ? response.data : []);
      });
  }, [ref]);

  useEffect(load, [load]);
  return { meta, files, versions, load };
}

/** The diff behind a diff view, fetched when the view asks for one. The
 *  special id "installed" compares against what is on disk. */
export function usePackageDiff(
  ref: PackageRef | null,
  view: PackageView,
  harness: HarnessId | null,
) {
  const showError = useProblemsStore((s) => s.showError);
  const [diff, setDiff] = useState<PackageDiff | null>(null);

  useEffect(() => {
    if (!ref || view.mode !== "diff") {
      setDiff(null);
      return;
    }
    let cancelled = false;
    setDiff(null);
    const sel = (id: string) =>
      id === "installed"
        ? ({ at: "installed" } as const)
        : ({ at: "commit", commit: id } as const);
    void commands
      .packageDiff(
        ref.scope,
        ref.kind,
        ref.name,
        sel(view.from),
        sel(view.to),
        harness,
      )
      .then((response) => {
        if (cancelled) return;
        if (response.status === "ok") setDiff(response.data);
        else showError({ title: "Couldn't compare", message: response.error });
      });
    return () => {
      cancelled = true;
    };
  }, [ref, view, harness, showError]);

  return diff;
}

/** The version-changing actions for one package, each applying the whole
 *  scope and refreshing the app's derived state after. `setBusy` drives
 *  the page's spinner; `reload` refetches the package's own data. */
export function packageVersionActions(
  ref: PackageRef,
  displayName: string,
  held: boolean,
  setBusy: (busy: boolean) => void,
  reload: () => void,
) {
  const showError = (message: string) =>
    useProblemsStore
      .getState()
      .showError({ title: VERSION_ERROR_TITLE, message });
  const afterChange = () => {
    reload();
    void useScanStore.getState().refresh();
    void useAuditStore.getState().refresh({ force: true });
  };
  const run = (
    call: Promise<{ status: "ok" } | { status: "error"; error: string }>,
    toastMessage: string,
  ) => {
    setBusy(true);
    void call.then((response) => {
      setBusy(false);
      if (response.status === "error") {
        showError(response.error);
        return;
      }
      toast.success(toastMessage);
      afterChange();
    });
  };

  const switchTo = (row: VersionRow) =>
    run(
      commands.packageSetRev(ref.scope, ref.kind, ref.name, row.id),
      updatedToastLabel(`${displayName} to ${versionRowLabel(row)}`),
    );

  // A held package moves its hold to the latest; a follower is brought
  // current by applying its scope — Update never silently pins a follower.
  const updateToLatest = (latest: VersionRow) =>
    held
      ? switchTo(latest)
      : run(
          commands.applyPlan(ref.scope, false, []),
          updatedToastLabel(displayName),
        );

  const follow = () =>
    run(
      commands.packageSetRev(ref.scope, ref.kind, ref.name, null),
      FOLLOW_SOURCE_TOAST,
    );

  return { switchTo, updateToLatest, follow };
}

/** One gate for every control that rewrites this package's manifest: the
 *  audit store's apply, a version switch in flight, the updates store's
 *  fork or discard, and the editor's save all touch the same file. */
export function useManifestBusy(switching: boolean): boolean {
  const auditBusy = useAuditStore((s) => s.busy);
  const updatesBusy = useUpdatesStore((s) => s.busy);
  const saving = useEditorStore((s) => s.saving);
  return auditBusy || switching || updatesBusy || saving;
}
