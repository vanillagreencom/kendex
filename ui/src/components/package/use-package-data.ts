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
import { packageReadFailedNote } from "@/lib/copy-updates";
import { installedCommits } from "@/lib/package-places";
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

/** How the page's own two gating reads went. Kept apart rather than folded
 *  into one answer: either one failing is a package this page could not
 *  read, and the timeline's failing on its own is separately why "there is
 *  nothing newer to move to" cannot be read off an empty version list. The
 *  file list is in neither — no Update ever turned on it, and folding it in
 *  would withhold the button over a read it does not depend on. */
export interface PackageReads {
  /** The record that says held or following. */
  record: ReadState;
  /** The timeline Update moves along. */
  timeline: ReadState;
}

const failedNote = ({ status, error }: ReadState): string | null =>
  status === "failed" && error !== null ? packageReadFailedNote(error) : null;

/** Why the package page has no Update when its own reads are the reason, or
 *  null when they are not. Silent while they are pending: the page is still
 *  filling in, and a header note on every open is noise rather than news.
 *
 *  This is not the page's first reason and must never be ranked as one. The
 *  commands behind these reads answer `Err` for a package that is not a
 *  managed one here as readily as for a read that went wrong — an undeclared
 *  item, a plugin, a path source — and their text is about declarations and
 *  revisions, not about a failure. `package.tsx` puts this behind everything
 *  the update read says for that reason: what is left is a declared package
 *  from a repository source whose kind plans one at a time, which is a read
 *  that genuinely did not land. */
export const packageReadNote = (reads: PackageReads): string | null =>
  failedNote(reads.record) ?? failedNote(reads.timeline);

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

  const load = useCallback(() => {
    if (!ref) return;
    const ticket = order.current.begin();
    // `settled` on all three: the generated wrapper rethrows a transport
    // failure rather than answering with one, and left raw the landing never
    // ran at all — the read stayed pending for the life of the view, the
    // note that says a read failed never appeared, and the rejection went
    // out unhandled.
    void settled(commands.packageMeta(ref.scope, ref.kind, ref.name)).then(
      (response) => {
        if (!order.current.lands(ticket)) return;
        setMeta(response.status === "ok" ? response.data : null);
        setRecord(readOf(response));
      },
    );
    void settled(commands.packageFiles(ref.scope, ref.kind, ref.name)).then(
      (response) => {
        if (!order.current.lands(ticket)) return;
        setFiles(response.status === "ok" ? response.data : []);
      },
    );
    void settled(commands.packageVersions(ref.scope, ref.kind, ref.name)).then(
      (response) => {
        if (!order.current.lands(ticket)) return;
        setVersions(response.status === "ok" ? response.data : []);
        setTimeline(readOf(response));
      },
    );
  }, [ref]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: the commit a landed update moves, not a value `load` closes over
  useEffect(load, [load, commit]);
  return { meta, files, versions, reads: { record, timeline }, load };
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
