import { useCallback, useEffect, useRef, useState } from "react";
import {
  commands,
  type HarnessId,
  type PackageDiff,
  type PackageFile,
  type PackageMeta_Serialize,
  type Scope,
  type VersionRow,
} from "@/bindings";
import { installedCommits, landedWrites } from "@/lib/package-places";
import type { PackageReads } from "@/lib/package-read-state";
import {
  READ_PENDING,
  type ReadState,
  readOf,
  readOrder,
} from "@/lib/read-state";
import { sameScope } from "@/lib/scope";
import { settled } from "@/lib/settled";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import type { PackageRef } from "@/stores/nav";
import { useProblemsStore } from "@/stores/problems";
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

/** The package page's reads, refetchable as one unit after a mutation.
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
  versions: VersionRow[];
  reads: PackageReads;
  load: () => void;
} {
  const [meta, setMeta] = useState<PackageMeta_Serialize | null>(null);
  const [files, setFiles] = useState<PackageFile[]>([]);
  const [versions, setVersions] = useState<VersionRow[]>([]);
  // How each of the two went, kept beside the values: a read that failed
  // leaves the same empty page as one that found nothing, and the reason it
  // came back with is the only thing that tells them apart.
  const [record, setRecord] = useState<ReadState>(READ_PENDING);
  const [timeline, setTimeline] = useState<ReadState>(READ_PENDING);
  // Whether the newest load is still out. Counted here rather than read off
  // the order below: one ticket covers three answers, and `outstanding` flips
  // on the first of them to land, so it is not this order's question to ask.
  const [reading, setReading] = useState(true);
  // One ticket per load, asked as each of its three answers arrives. Reads
  // of this package overlap on every ordinary path — a focus reload moving
  // the commit under a mount, a move to another package, the read-back
  // behind a version switch — and only the newest-begun load may write. An
  // older landing would put one package's files and read state under
  // another's name, and the header's Update turns on that read state.
  const order = useRef(readOrder());
  const commit = useUpdatesStore((s) =>
    ref === null
      ? ""
      : installedCommits(s.rows, ref.kind, ref.name, [ref.scope]),
  );
  // The commit's other half: a write that committed and could not be read
  // back leaves the commit where it was, and the files under it are new all
  // the same.
  const written = useUpdatesStore((s) =>
    ref === null ? "" : landedWrites(s.writes, ref.kind, ref.name, [ref.scope]),
  );

  const load = useCallback(() => {
    if (!ref) return;
    const ticket = order.current.begin();
    let left = 3;
    setReading(true);
    // Whether this answer is the newest load's to write, and the last of its
    // three when it is. A superseded load never reaches its own count, so
    // the load on screen is the only one that can say it has finished.
    const lands = () => {
      if (!order.current.lands(ticket)) return false;
      left -= 1;
      if (left === 0) setReading(false);
      return true;
    };
    // `settled` on all three: the generated wrapper rethrows a transport
    // failure rather than answering with one, and left raw the landing never
    // ran at all — the read stayed pending for the life of the view, the
    // note that says a read failed never appeared, and the rejection went
    // out unhandled.
    void settled(commands.packageMeta(ref.scope, ref.kind, ref.name)).then(
      (response) => {
        if (!lands()) return;
        setMeta(response.status === "ok" ? response.data : null);
        setRecord(readOf(response));
      },
    );
    void settled(commands.packageFiles(ref.scope, ref.kind, ref.name)).then(
      (response) => {
        if (!lands()) return;
        setFiles(response.status === "ok" ? response.data : []);
      },
    );
    void settled(commands.packageVersions(ref.scope, ref.kind, ref.name)).then(
      (response) => {
        if (!lands()) return;
        setVersions(response.status === "ok" ? response.data : []);
        setTimeline(readOf(response));
      },
    );
  }, [ref]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: what a landed update moves, not values `load` closes over
  useEffect(load, [load, commit, written]);
  return { meta, files, versions, reads: { record, timeline, reading }, load };
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
