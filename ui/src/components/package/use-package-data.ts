import { useCallback, useEffect, useState } from "react";
import {
  commands,
  type HarnessId,
  type PackageDiff,
  type PackageFile,
  type PackageMeta_Serialize,
  type PackageUpdate_Serialize,
  type Scope,
  type VersionRow,
} from "@/bindings";
import {
  FOLLOW_SOURCE_TOAST,
  updatedToastLabel,
  VERSION_ERROR_TITLE,
} from "@/lib/copy";
import { sameScope } from "@/lib/scope";
import { settled } from "@/lib/settled";
import { versionRowLabel } from "@/lib/versions";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import type { PackageRef } from "@/stores/nav";
import { useProblemsStore } from "@/stores/problems";
import { useScanStore } from "@/stores/scan";
import { holdingBusy, useUpdatesStore } from "@/stores/updates";
import { sayApply } from "@/stores/updates-apply";
import { writeRev, writeUpdate } from "@/stores/updates-writes";

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
  // Every one of these applies a plan that can refuse a rendering, so
  // none of them toasts off the click: the command's own report says what
  // reached the files, and `done` is only this surface's word for having
  // written the package. This page has no edited-row filter, and a refusal
  // is broader than an edit anyway — files kendex never put there, a
  // provenance clash — so the held answer arrives here whatever the page
  // believes about edits.
  // Under the updates store's `busy` as well as the page's own spinner:
  // these commit like any update does, and the Updates page's check refuses
  // on that flag alone. Without it a check runs beside this write and lands
  // a report built before it.
  const run = (
    call: Promise<
      | { status: "ok"; data: PackageUpdate_Serialize }
      | { status: "error"; error: string }
    >,
    done: string,
  ) => {
    setBusy(true);
    return holdingBusy(async () => {
      // A transport failure rejects rather than refusing. Unwrapped it
      // would skip the report, leave `setBusy` up for the life of the view
      // and skip the read-back this promises either way.
      const response = await settled(call);
      setBusy(false);
      if (response.status === "error") {
        showError(response.error);
        // An error is not proof that nothing changed: `package_set_rev`
        // persists the revision and only then applies, so a failed apply
        // answers over a manifest that already moved. The page reads back
        // either way, or it shows the old version as settled.
        afterChange();
        return;
      }
      // One package's apply, so a removal it reports is that package's.
      sayApply(done, response.data, 1);
      afterChange();
    });
  };

  const switchTo = (row: VersionRow) =>
    run(
      writeRev(ref.scope, ref.kind, ref.name, row.id),
      updatedToastLabel(`${displayName} to ${versionRowLabel(row)}`),
    );

  // A held package moves its hold to the latest; a follower is brought
  // current by the single-package apply — Update never silently pins a
  // follower, and does not move the scope's other followers along.
  const updateToLatest = (latest: VersionRow) =>
    held
      ? switchTo(latest)
      : run(
          writeUpdate(ref.scope, ref.kind, ref.name),
          updatedToastLabel(displayName),
        );

  const follow = () =>
    run(writeRev(ref.scope, ref.kind, ref.name, null), FOLLOW_SOURCE_TOAST);

  return { switchTo, updateToLatest, follow };
}

/** One gate for every control that rewrites this package's manifest: the
 *  audit store's apply, a version switch in flight, the updates store's
 *  fork or discard, a Follow source flip settling, and the editor's save
 *  all touch the same file. The controls here command the engine directly
 *  rather than through the updates store's chain, and two commands that
 *  both read a manifest before either applies leave the second saving its
 *  stale copy over the first — so this gate, not ordering, is what keeps
 *  them apart.
 *
 *  `scopes` is every scope the page's controls can write, not only the one
 *  it was opened at: Delete, the Projects tab's per-place removal, and the
 *  enable/disable toggle each run over places the page does not name. */
export function useManifestBusy(switching: boolean, scopes: Scope[]): boolean {
  const auditBusy = useAuditStore((s) => s.busy);
  const updatesBusy = useUpdatesStore((s) => s.busy);
  const settling = useUpdatesStore((s) =>
    s.pendingFollows.some((one) =>
      scopes.some((scope) => sameScope(one.scope, scope)),
    ),
  );
  const saving = useEditorStore((s) => s.saving);
  return auditBusy || switching || updatesBusy || settling || saving;
}

/** The gate for the three version-changing controls this page keeps on
 *  screen through a check — Update, switch version, and Follow source.
 *  They commit through `holdingBusy`, so a check must not run beside them.
 *  The Projects tab's Update and Update all commit the same way and need
 *  no gate here: `place.updatable` reads `rowUnsettled`, which carries
 *  `checking`, so neither is rendered while a check is out. Save, Delete
 *  and the enable/disable toggle write through the audit or editor store
 *  and take no part — gating them on a mirror fetch would cost a save. */
export function useVersionsBusy(manifestBusy: boolean): boolean {
  const checking = useUpdatesStore((s) => s.checking);
  return manifestBusy || checking;
}
