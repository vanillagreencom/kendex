import { useCallback, useEffect, useRef, useState } from "react";
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
import {
  type PackageReads,
  SOURCE_READ_LANDED,
  SOURCE_READ_PENDING,
  type SourceRead,
  sourceReadOf,
} from "@/lib/package-read-state";
import {
  READ_LANDED,
  READ_PENDING,
  type ReadState,
  readOf,
  readOrder,
} from "@/lib/read-state";
import { settled } from "@/lib/settled";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import type { PackageRef } from "@/stores/nav";
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
} {
  const [meta, setMeta] = useState<PackageMeta_Serialize | null>(null);
  const [files, setFiles] = useState<PackageFile[]>([]);
  // The README the Overview shows. Read here rather than by the component
  // that draws it: an update or a version switch rewrites the installed
  // files without moving the address, so a read keyed on the package's
  // name would go on showing the replaced copy's words.
  const [readme, setReadme] = useState<ItemSource | null>(null);
  const [versions, setVersions] = useState<VersionRow[]>([]);
  // How each of the four went, kept beside the values: a read that failed
  // leaves the same empty page as one that found nothing, and the reason it
  // came back with is the only thing that tells them apart. The three that
  // open the source each carry the source core said no fetch has
  // downloaded, where that was its answer: a landed read with nothing to
  // draw, told apart from one that failed because only a refresh, never a
  // re-read, lifts it.
  const [record, setRecord] = useState<ReadState>(READ_PENDING);
  const [timeline, setTimeline] = useState<SourceRead>(SOURCE_READ_PENDING);
  const [filesRead, setFilesRead] = useState<SourceRead>(SOURCE_READ_PENDING);
  const [readmeRead, setReadmeRead] = useState<SourceRead>(SOURCE_READ_PENDING);
  // Whether the newest load is still out. Counted here rather than read off
  // the order below: one ticket covers four answers, and `outstanding` flips
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
  // back leaves the commit where it was, and the files under it have
  // changed all the same.
  const written = useUpdatesStore((s) =>
    ref === null ? "" : landedWrites(s.writes, ref.kind, ref.name, [ref.scope]),
  );

  const load = useCallback(() => {
    if (!ref) return;
    // A page about an installation nothing recorded has no declaration to
    // read. Its address — this scope, kind and name — may belong to a
    // package that IS recorded, and asking these three for it would put
    // that package's record, files and version history under this one's
    // name. The reads are not merely hidden: they are never issued, so
    // there is nothing on hand for a later surface to draw from.
    if (!addressesDeclaration(ref)) {
      order.current.begin();
      setMeta(null);
      setFiles([]);
      setVersions([]);
      setRecord(READ_LANDED);
      setFilesRead(SOURCE_READ_LANDED);
      setTimeline(SOURCE_READ_LANDED);
      setReading(false);
      return;
    }
    const ticket = order.current.begin();
    let left = 4;
    setReading(true);
    // Whether this answer is the newest load's to write, and the last of its
    // four when it is. A superseded load never reaches its own count, so
    // the load on screen is the only one that can say it has finished.
    const lands = () => {
      if (!order.current.lands(ticket)) return false;
      left -= 1;
      if (left === 0) setReading(false);
      return true;
    };
    // `settled` on all four: it normalizes a refusal that says nothing,
    // and it is the last guard behind the wrapper's own fold. A landing that
    // never ran leaves the read pending for the life of the view, the note
    // that says a read failed never appears, and the rejection goes out
    // unhandled.
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
        setFilesRead(sourceReadOf(response));
      },
    );
    void settled(commands.packageReadme(ref.scope, ref.kind, ref.name)).then(
      (response) => {
        if (!lands()) return;
        setReadme(response.status === "ok" ? response.data : null);
        setReadmeRead(sourceReadOf(response));
      },
    );
    void settled(commands.packageVersions(ref.scope, ref.kind, ref.name)).then(
      (response) => {
        if (!lands()) return;
        setVersions(response.status === "ok" ? response.data : []);
        setTimeline(sourceReadOf(response));
      },
    );
  }, [ref]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: what a landed update moves, not values `load` closes over
  useEffect(load, [load, commit, written]);
  return {
    meta,
    files,
    readme,
    versions,
    reads: {
      record,
      timeline,
      files: filesRead,
      readme: readmeRead,
      reading,
    },
    load,
  };
}

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
