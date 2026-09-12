import { useEffect, useMemo, useState } from "react";
import type { HarnessId, Scope, VersionRow } from "@/bindings";
import { CustomizeSaveBar } from "@/components/customize/customize-save-bar";
import { ChangesPanel } from "@/components/files/changes-panel";
import { ChangesViewer } from "@/components/files/changes-viewer";
import { DeleteDialog } from "@/components/package/delete-dialog";
import { MissingFilesNotice } from "@/components/package/missing-files-notice";
import { PackageActions } from "@/components/package/package-actions";
import { PackageFiles } from "@/components/package/package-files";
import { PackageHeader } from "@/components/package/package-header";
import { PackageOverview } from "@/components/package/package-overview";
import { PackageTabs } from "@/components/package/package-tabs";
import { packageVersionActions } from "@/components/package/package-version-actions";
import {
  type Comparison,
  diffHarness,
  useManifestBusy,
  usePackageData,
  usePackageDiff,
} from "@/components/package/use-package-data";
import { PackagesNote } from "@/components/packages-note";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import {
  REPAIR_CONFIRMING_NOTE,
  SCAN_AGAIN_LABEL,
  SCAN_FAILED_TITLE,
  YOUR_EDITS_SIDE,
  yourEditsInSide,
} from "@/lib/copy";
import {
  groupFor,
  groupItems,
  groupRef,
  groupScopes,
  installationAt,
  summaryAt,
} from "@/lib/derive";
import { harnessName, packageDisplayName } from "@/lib/labels";
import { PAGE_GUTTER } from "@/lib/layout";
import {
  addressesDeclaration,
  usePackageIndex,
  usePackagesKnown,
  useSummaryIndex,
} from "@/lib/package-identity";
import { usePackageMark } from "@/lib/package-mark";
import { vendorAt } from "@/lib/package-places";
import { packageReadNote, unfetchedNote } from "@/lib/package-read-state";
import { rescanEverything } from "@/lib/rescan";
import { sameScope, scopeKey } from "@/lib/scope";
import {
  packageForkEdited,
  packageRequiredBy,
  packageUpdateNote,
  rowsKnown,
  updatesReadNote,
} from "@/lib/updates-read-state";
import { cn } from "@/lib/utils";
import {
  hasNewer,
  installedRow,
  latestRow,
  updateOffer,
  versionRowLabel,
} from "@/lib/versions";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";

/** One package, full page: what it is as installed, and what you have
 *  changed about it. */
export function PackagePage() {
  const ref = useNavStore((s) => s.packageRef);
  const initialView = useNavStore((s) => s.packageView);
  const clearPackageView = useNavStore((s) => s.clearPackageView);
  const back = useNavStore((s) => s.back);
  const result = useScanStore((s) => s.result);
  const scanError = useScanStore((s) => s.error);
  const scanning = useScanStore((s) => s.scanning);
  const toggle = useAuditStore((s) => s.toggle);
  const { openScope } = useEditorStore();

  // What the slide-in panel is comparing, or null with nothing open. The
  // page opens on it when Updates sent the reader here to preview a
  // change; every other way in leaves the tabs on screen.
  const [comparison, setComparison] = useState<Comparison | null>(() =>
    initialView?.mode === "diff"
      ? {
          from: initialView.from,
          to: initialView.to,
          fromLabel: initialView.from.slice(0, 7),
          toLabel: initialView.to.slice(0, 7),
        }
      : null,
  );
  // Which tab the link that opened this page asked for, read once on mount:
  // the store's copy is cleared straight after, and re-reading it would
  // send the page back to that tab whenever the reader picked another.
  const [openOn] = useState<"overview" | "safety">(
    initialView?.mode === "safety" ? "safety" : "overview",
  );
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [switching, setSwitching] = useState(false);
  useEffect(() => {
    if (initialView) clearPackageView();
  }, [initialView, clearPackageView]);

  // The manifest this package's own edits live in, loaded up front so the
  // header can say whether there are any before the tab is opened.
  useEffect(() => {
    // Only where a declaration is what this page is about: the editor
    // opens a place's manifest, and on an observed row that manifest
    // belongs to whatever package shares its name.
    if (ref && addressesDeclaration(ref)) void openScope(ref.scope);
  }, [ref, openScope]);

  const packageOf = usePackageIndex();
  // The words the package's author wrote, from the same join the row and
  // its preview read, so the page cannot describe it differently.
  const summaryOf = useSummaryIndex();
  const packagesKnown = usePackagesKnown();
  // Found by the whole identity the link carried, not by what each tool
  // stores this package as: a tool that keeps a hook as a rule or a command
  // as a skill would otherwise leave the page with nothing to show, and a
  // package and an installation nothing recorded can wear one kind and name
  // and would otherwise open each other's page — its files, chips and diff
  // target from one of them, its meta, versions and Delete from the other.
  // Nothing to find until the identity answers for the scan on screen:
  // grouping it against an older answer would open a row that is not the
  // one the link named.
  const group = useMemo(
    () =>
      ref && result && packageOf
        ? groupFor(groupItems(result.items, packageOf, summaryOf), ref)
        : null,
    [ref, result, packageOf, summaryOf],
  );

  const mutating = useManifestBusy(switching);
  const {
    meta,
    files,
    readme,
    versions,
    reads,
    load: reload,
  } = usePackageData(ref);
  const diff = usePackageDiff(
    ref,
    comparison,
    diffHarness(comparison, installationAt(group, ref?.scope)?.harness ?? null),
  );
  // Why this place has no Update, or null when nothing withholds one. A
  // string, so this selector answers the same value on every render that
  // changes nothing.
  // Every value below is read out of the records by scope, kind and name —
  // the declaration's address, which an installation nothing recorded
  // shares with whatever package IS recorded under it. So each is asked
  // only for a page that speaks for a declaration; `declaring` is the one
  // decision, and a page without one shows none of them rather than the
  // other package's.
  const declaring = ref !== null && addressesDeclaration(ref);
  const asked = declaring ? ref : null;
  const withheld = useUpdatesStore((s) => packageUpdateNote(s, asked));
  // How the update read itself is standing, which is about the machine rather
  // than about this package, and silent where it has a row for this place. A
  // string, for the same reason.
  const standing = useUpdatesStore((s) => updatesReadNote(s, asked));
  // Why this package is installed when nobody asked for it: the package
  // that requires it, named. A string, so this selector answers the same
  // value on every render that changes nothing.
  const requiredBy = useUpdatesStore((s) => packageRequiredBy(s, asked));
  // A fork the person has since edited by hand: part of what the package
  // is, said beside the fork badge rather than as something to settle.
  const forkEdited = useUpdatesStore((s) => packageForkEdited(s, asked));

  const mark = usePackageMark(declaring ? group : null);
  // The package can still be installed elsewhere while this place has no
  // copy of it — a page about a place that does not have it has nothing
  // to show and no actions that would land anywhere.
  // A place the scan no longer sees the copy in, but whose update row
  // says a recorded file is gone, still has this package: the file is
  // what the row's repair puts back, and this page is where the repair
  // is offered. Read off the row the planner produced, never a second
  // look at the disk, and only from rows the read has confirmed.
  const missingHere = useUpdatesStore(
    (s) =>
      asked !== null &&
      rowsKnown(s) &&
      s.rows.some(
        (row) =>
          row.kind === asked.kind &&
          row.name === asked.name &&
          sameScope(row.scope, asked.scope) &&
          row.filesMissing,
      ),
  );
  // The installation this page is about. A package can be installed in
  // several places and the page names one of them, so the actions that
  // open files reach that place's copy. Falling back to another place's
  // would have the page describe one place while its buttons work on
  // another.
  const primary = installationAt(group, ref?.scope);
  const installedHere = primary !== undefined || missingHere;

  // Once this page has drawn the repair for a place, it holds that place
  // until the scan sees the copy again or the row says the file is still
  // gone. The two reads behind those can disagree for a while — the rows
  // clear the fact the moment the file is back, and a scan that failed
  // or is still out holds no copy — and a page that trusted either alone
  // in that window would leave, or go blank, over a repair that worked.
  // Keyed by the place, so a link to another package starts unheld.
  const placeKey = asked
    ? `${asked.kind}:${asked.name}:${scopeKey(asked.scope)}`
    : null;
  const [repairDrawnFor, setRepairDrawnFor] = useState<string | null>(null);
  useEffect(() => {
    if (missingHere && primary === undefined) setRepairDrawnFor(placeKey);
  }, [missingHere, primary, placeKey]);
  const held = placeKey !== null && repairDrawnFor === placeKey;

  // The scan has lost this package (removed, renamed): leave the way the
  // user came. Only once the join has said which observations are this
  // package — before that a package a tool stores under another identity
  // is not lost, it is not yet resolved, and leaving would throw the
  // reader off a page that was about to draw. Never while the page is
  // held over a repair: the scan losing the copy is the very state the
  // repair was drawn for.
  useEffect(() => {
    if (ref && result && packagesKnown && !installedHere && !held) back();
  }, [ref, result, packagesKnown, installedHere, held, back]);

  if (!ref) return null;
  // The read that says which installations are one package has not
  // answered for the scan on screen, so which row this link named cannot
  // be said yet. The links that reach here — Updates, Customize, a
  // marketplace — stay on screen through it, so the page says what it is
  // waiting on, and offers the read again where that read failed, rather
  // than going blank under a link that still works.
  if (!packagesKnown) {
    return (
      <div className={cn("flex min-h-0 flex-1 flex-col pt-6", PAGE_GUTTER)}>
        <PackagesNote counting />
      </div>
    );
  }
  // No copy the scan can see here — or anywhere, when this was the only
  // one — and the row says why: a recorded file is gone. Every control
  // below opens or lists files at this place, so none of them can stand;
  // the page is the header and the repair, built from the link's own
  // scope, kind and name, which is all the two need. The summary is the
  // observed copy's, so it is absent with the copy. Held over a repair
  // with the row no longer saying the file is gone, the page waits for
  // the scan in the notice's place: the failure with its retry where the
  // scan failed, otherwise the read still out.
  if (!group || !primary) {
    if (!missingHere && !held) return null;
    return (
      <div className="flex min-h-0 flex-1 flex-col">
        <PackageHeader
          kind={ref.kind}
          displayName={packageDisplayName(ref)}
          summary={summaryAt(group, ref.scope, summaryOf)}
          forked={meta?.fork != null}
          forkEdited={forkEdited}
          mark={mark}
          requiredBy={requiredBy}
          action={null}
        />
        <div className={cn("pt-6", PAGE_GUTTER)}>
          {missingHere ? (
            <MissingFilesNotice
              scope={ref.scope}
              kind={ref.kind}
              name={ref.name}
              onResolved={reload}
            />
          ) : scanError !== null ? (
            <StatusNote
              tone="warning"
              title={SCAN_FAILED_TITLE}
              action={
                <Button
                  size="sm"
                  variant="outline"
                  disabled={scanning}
                  onClick={() => void rescanEverything({ announce: true })}
                >
                  {SCAN_AGAIN_LABEL}
                </Button>
              }
            >
              {scanError}
            </StatusNote>
          ) : (
            <p className="text-sm text-muted-foreground">
              {REPAIR_CONFIRMING_NOTE}
            </p>
          )}
        </div>
      </div>
    );
  }
  // Whether this page has a declaration behind it. Asked once, and the
  // controls that write one are simply not handed a handler: an
  // installation nothing recorded shares its scope, kind and name with
  // whatever package may be recorded under them, and every one of those
  // writes would land on that package instead. What stays is the
  // installation itself — its files, its places, its details — and taking
  // it off the machine remains the Not-managed path's, which addresses the
  // file rather than a declaration.
  const declares = declaring;

  const displayName = packageDisplayName(ref);
  const installed = installedRow(versions);
  const latest = latestRow(versions);
  // The button, the note where it would have been, and whether reading again
  // can lift that note: one answer, ranked in `versions.ts`, so the three can
  // never disagree.
  const offer = updateOffer({
    latest,
    installed,
    metaLoaded: meta != null,
    unfetched: unfetchedNote(reads),
    withheld,
    readNote: packageReadNote(reads),
    standing,
  });

  // Every scope this package sits in, one at a time — each apply takes
  // that scope's writer lock — and stopping at the first that fails.
  const inEveryScope = async (act: (scope: Scope) => Promise<boolean>) => {
    for (const scope of groupScopes(group)) {
      if (!(await act(scope))) return;
    }
  };

  const { switchTo, updateToLatest, follow } = packageVersionActions(
    ref,
    displayName,
    meta?.rev != null,
    setSwitching,
    reload,
  );

  const compare = (row: VersionRow) =>
    installed &&
    setComparison({
      from: installed.id,
      to: row.id,
      fromLabel: versionRowLabel(installed),
      toLabel: versionRowLabel(row),
    });

  const compareEdits = (harness?: HarnessId) => {
    if (!installed) return;
    setComparison({
      from: installed.id,
      to: "installed",
      fromLabel: versionRowLabel(installed),
      toLabel: harness
        ? yourEditsInSide(harnessName(harness))
        : YOUR_EDITS_SIDE,
      harness,
    });
  };

  const overview = (
    <PackageOverview
      reference={ref}
      group={group}
      primary={primary}
      meta={meta}
      versions={versions}
      readme={readme}
      readmeRead={reads.readme}
      readsRunning={reads.reading}
      busy={mutating}
      declares={declares}
      onToggle={
        declares
          ? (enable) =>
              void inEveryScope((scope) =>
                toggle(scope, group.kind, group.name, enable),
              )
          : undefined
      }
      onSwitchVersion={switchTo}
      onCompare={compare}
      onCompareEdits={compareEdits}
      onFollow={follow}
      onReload={reload}
    />
  );

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <PackageHeader
        kind={group.kind}
        displayName={displayName}
        summary={summaryAt(group, ref.scope, summaryOf)}
        forked={meta?.fork != null}
        forkEdited={forkEdited}
        mark={mark}
        requiredBy={requiredBy}
        action={
          <PackageActions
            scope={primary.scope}
            kind={group.kind}
            name={group.name}
            primaryPath={primary.path}
            updateAvailable={offer.can}
            previewAvailable={hasNewer(latest) && installed != null}
            withheldNote={offer.note}
            onRetryRead={offer.retry ? reload : undefined}
            retryRunning={reads.reading}
            busy={mutating}
            onUpdate={
              declares ? () => latest && updateToLatest(latest) : undefined
            }
            onPreview={declares ? () => latest && compare(latest) : undefined}
            onDelete={declares ? () => setConfirmDelete(true) : undefined}
          />
        }
      />
      <PackageTabs
        kind={group.kind}
        name={group.name}
        scope={ref.scope}
        scopes={groupScopes(group)}
        installations={group.installations}
        declares={declares}
        vendor={vendorAt(group.installations, ref.scope)}
        harnesses={group.harnesses as HarnessId[]}
        busy={mutating}
        openOn={openOn}
        onDelete={declares ? () => setConfirmDelete(true) : undefined}
        overview={overview}
        files={
          <PackageFiles
            scope={ref.scope}
            kind={group.kind}
            name={group.name}
            files={files}
            read={reads.files}
            retryRunning={reads.reading}
            onRetry={reload}
          />
        }
      />
      <ChangesPanel
        open={comparison !== null}
        onClose={() => setComparison(null)}
        fromLabel={comparison?.fromLabel ?? ""}
        toLabel={comparison?.toLabel ?? ""}
      >
        <ChangesViewer diff={diff} />
      </ChangesPanel>
      {/* The editor's dirty state belongs to the last manifest it opened,
          and an observed page opens none — so a bar here would offer to
          save another package's settings from a page that is not about
          it. On the same one decision as every other declaration write.
          `CustomizeSaveBar` answers the dirty half itself, and carries the
          destination summary a credential save has to show first. */}
      {declares ? <CustomizeSaveBar busy={mutating} /> : null}
      <DeleteDialog
        open={confirmDelete}
        onOpenChange={setConfirmDelete}
        reference={groupRef(group)}
        scopes={groupScopes(group)}
      />
    </div>
  );
}
