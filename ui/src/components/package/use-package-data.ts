import { useCallback, useEffect, useLayoutEffect, useState } from "react";
import {
  commands,
  type HarnessId,
  type ItemSource,
  type PackageDiff,
  type PackageFile,
  type PackageMeta_Serialize,
  type VersionRow,
} from "@/bindings";
import { addressesDeclaration } from "@/lib/package-identity";
import { installedCommits, landedWrites } from "@/lib/package-places";
import type { PackageReads } from "@/lib/package-read-state";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import type { PackageRef } from "@/stores/nav";
import {
  ensurePackage,
  PACKAGE_UNREAD,
  packageReadKey,
  readPackage,
  usePackageReads,
} from "@/stores/package-reads";
import { useProblemsStore } from "@/stores/problems";
import { useUpdatesStore } from "@/stores/updates";

/** What the package page's changes panel is comparing. Null everywhere it
 *  is closed, so "is a comparison open" and "what is it of" are one
 *  answer rather than two that can disagree. */
export interface Comparison {
  from: string;
  to: string;
  /** The two sides as the panel's bar names them: a version, "installed",
   *  the tool whose copy was edited. */
  fromLabel: string;
  toLabel: string;
  /** The rendering to read the installed side from, when the comparison is
   *  about one tool's edited copy rather than the package's primary
   *  installation. */
  harness?: HarnessId;
}

/** Which rendering a diff reads: the one the comparison names, else the
 *  package's primary installation. */
export const diffHarness = (
  comparison: Comparison | null,
  primary: HarnessId | null,
): HarnessId | null => comparison?.harness ?? primary;

/** The package page's reads, refetchable as one unit after a mutation.
 *
 *  Kept by `stores/package-reads.ts` past the page, so coming back to a
 *  package nothing has changed draws what was already read; that module
 *  says what keeps an answer current.
 *
 *  Read again when the commit installed in the place this page names moves:
 *  an update started from the Projects tab commits through the updates
 *  store and never through `load`, so without that the Overview would go on
 *  showing the files and version of the copy the update replaced and the
 *  header would go on offering an update already applied. Keyed on the
 *  commit, the way the Projects tab's own re-read is, so an unrelated
 *  updates-store touch reads nothing. */
export function usePackageData(ref: PackageRef | null): {
  meta: PackageMeta_Serialize | null;
  files: PackageFile[];
  readme: ItemSource | null;
  versions: VersionRow[];
  reads: PackageReads;
  load: () => void;
  ensure: () => void;
} {
  const commit = useUpdatesStore((s) =>
    ref === null
      ? ""
      : installedCommits(s.rows, ref.kind, ref.name, [ref.scope]),
  );
  // The commit's other half: a write that committed and could not be read
  // back leaves the commit where it was, and the files under it have
  // changed all the same.
  const written = useUpdatesStore((s) =>
    ref === null ? "" : landedWrites(s.writes, ref.kind, ref.name, [ref.scope]),
  );
  const held = usePackageReads((s) =>
    ref === null ? undefined : s.answers[packageReadKey(ref)],
  );

  const load = useCallback(() => {
    if (ref) readPackage(ref, { commit, written }, "kept");
  }, [ref, commit, written]);

  // Run again by the Files tab as it opens: these inputs move with the
  // installed commit and the writes landed at the place, and a refocus or a
  // fetch moves neither, while the tab draws file bytes either can change.
  const ensure = useCallback(() => {
    if (ref) ensurePackage(ref, { commit, written });
  }, [ref, commit, written]);

  // Before paint: an answer that stopped being current is replaced before
  // the page is drawn from it, so for no frame does a kept record or
  // timeline stand under the Update it would enable.
  useLayoutEffect(ensure, [ensure]);

  return {
    meta: held?.meta ?? null,
    files: held?.files ?? NO_FILES,
    readme: held?.readme ?? null,
    versions: held?.versions ?? NO_VERSIONS,
    reads: held?.reads ?? PACKAGE_UNREAD,
    load,
    ensure,
  };
}

const NO_FILES: PackageFile[] = [];
const NO_VERSIONS: VersionRow[] = [];

/** The diff behind the changes panel, fetched when a comparison opens. The
 *  special id "installed" compares against what is on disk. */
export function usePackageDiff(
  ref: PackageRef | null,
  comparison: Comparison | null,
  harness: HarnessId | null,
) {
  const showError = useProblemsStore((s) => s.showError);
  const [diff, setDiff] = useState<PackageDiff | null>(null);

  useEffect(() => {
    if (!ref || !comparison || !addressesDeclaration(ref)) {
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
        sel(comparison.from),
        sel(comparison.to),
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
  }, [ref, comparison, harness, showError]);

  return diff;
}

/** One gate for every control that rewrites this package's manifest: the
 *  audit store's apply, a version switch in flight, the updates store's
 *  fork or discard, and the editor's save all touch the same file. The
 *  controls here command the engine directly rather than through the
 *  updates store's chain, and two commands that both read a manifest
 *  before either applies leave the second saving its stale copy over the
 *  first — so this gate, not ordering, is what keeps them apart.
 *
 *  Page-wide, because the updates store's write hold is: every scope the
 *  page's controls can write — Delete, the Projects tab's per-place
 *  removal, the enable/disable toggle — is held by the same flag. */
export function useManifestBusy(switching: boolean): boolean {
  const auditBusy = useAuditStore((s) => s.busy);
  const updatesBusy = useUpdatesStore((s) => s.busy);
  const saving = useEditorStore((s) => s.saving);
  return auditBusy || switching || updatesBusy || saving;
}

/** The gate for the three version-changing controls this page keeps on
 *  screen through a check — Update, switch version, and Follow the source
 *  again.
 *  They commit through `holdingBusy`, so a check must not run beside them.
 *  The Projects tab's Update and Update all commit the same way and need
 *  no gate here: `place.updatable` reads `readUnsettled`, which carries
 *  `checking`, so neither is rendered while a check is out. Save, Delete
 *  and the enable/disable toggle write through the audit or editor store
 *  and take no part — gating them on a mirror fetch would cost a save. */
export function useVersionsBusy(manifestBusy: boolean): boolean {
  const checking = useUpdatesStore((s) => s.checking);
  return manifestBusy || checking;
}
