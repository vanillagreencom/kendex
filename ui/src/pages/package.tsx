import { useEffect, useMemo, useState } from "react";
import type { HarnessId, Scope, VersionRow } from "@/bindings";
import { SaveBar } from "@/components/customize/save-bar";
import { DeleteDialog } from "@/components/package/delete-dialog";
import { PackageActions } from "@/components/package/package-actions";
import { PackageBody } from "@/components/package/package-body";
import { PackageHeader } from "@/components/package/package-header";
import { PackageTabs } from "@/components/package/package-tabs";
import {
  diffHarness,
  type PackageView,
  packageVersionActions,
  useManifestBusy,
  usePackageData,
  usePackageDiff,
} from "@/components/package/use-package-data";
import { groupItems, groupScopes, installationAt } from "@/lib/derive";
import { packageDisplayName } from "@/lib/labels";
import { usePackageMark } from "@/lib/package-mark";
import { vendorAt } from "@/lib/package-places";
import { packageUpdateNote } from "@/lib/updates-read-state";
import {
  canUpdatePackage,
  installedRow,
  latestRow,
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
  const toggle = useAuditStore((s) => s.toggle);
  const { dirty, saving, openScope, load, save } = useEditorStore();

  const [view, setView] = useState<PackageView>(() =>
    initialView
      ? {
          mode: "diff",
          from: initialView.from,
          to: initialView.to,
          fromLabel: initialView.from.slice(0, 7),
          toLabel: initialView.to.slice(0, 7),
        }
      : { mode: "files", file: null },
  );
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [switching, setSwitching] = useState(false);
  useEffect(() => {
    if (initialView) clearPackageView();
  }, [initialView, clearPackageView]);

  // The manifest this package's own edits live in, loaded up front so the
  // header can say whether there are any before the tab is opened.
  useEffect(() => {
    if (ref) void openScope(ref.scope);
  }, [ref, openScope]);

  const group = useMemo(() => {
    if (!ref || !result) return null;
    const matching = result.items.filter(
      (item) => item.kind === ref.kind && item.name === ref.name,
    );
    return groupItems(matching)[0] ?? null;
  }, [ref, result]);

  // Every manifest this page's controls can write: the place it was opened
  // at, and each place Delete and the enable/disable toggle reach.
  const mutating = useManifestBusy(switching, [
    ...(ref ? [ref.scope] : []),
    ...(group ? groupScopes(group) : []),
  ]);
  const { meta, files, versions, load: reload } = usePackageData(ref);
  const diff = usePackageDiff(
    ref,
    view,
    diffHarness(view, installationAt(group, ref?.scope)?.harness ?? null),
  );
  // Why this place has no Update, or null when nothing withholds one. A
  // string, so this selector answers the same value on every render that
  // changes nothing.
  const withheld = useUpdatesStore((s) => packageUpdateNote(s, ref));

  const mark = usePackageMark(group);
  // The package can still be installed elsewhere while this place has no
  // copy of it — a page about a place that does not have it has nothing
  // to show and no actions that would land anywhere.
  const installedHere = installationAt(group, ref?.scope) !== undefined;

  // The scan no longer knows this package (removed, renamed): leave the
  // way the user came.
  useEffect(() => {
    if (ref && result && !installedHere) back();
  }, [ref, result, installedHere, back]);

  if (!ref || !group) return null;
  // The installation this page is about. A package can be installed in
  // several places and the page names one of them, so the actions that
  // open files reach that place's copy. Falling back to another place's
  // would have the page describe one place while its buttons work on
  // another.
  const primary = installationAt(group, ref.scope);
  if (!primary) return null;

  const displayName = packageDisplayName(ref);
  const installed = installedRow(versions);
  const latest = latestRow(versions);
  // The button and the note beside it come from the one string above, so
  // wherever there is a newer version to move to, a reason the update read
  // carries — its own state, or the row's — is always said where the
  // button would have been. Update also waits for meta (held vs
  // following), and takes its newness from this page's own version rows.
  const canUpdate = canUpdatePackage({
    latest,
    installed,
    metaLoaded: meta != null,
    withheld,
  });
  // A newer version to move to and an installed one to move from: what
  // the read-only diff needs, and what the note below has to explain.
  const newer = latest != null && !latest.installed;
  const updateWithheld = newer ? withheld : null;

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
    setView({
      mode: "diff",
      from: installed.id,
      to: row.id,
      fromLabel: versionRowLabel(installed),
      toLabel: versionRowLabel(row),
    });

  const body = (
    <PackageBody
      reference={ref}
      group={group}
      primary={primary}
      meta={meta}
      versions={versions}
      files={files}
      installed={installed}
      view={view}
      setView={setView}
      diff={diff}
      busy={mutating}
      onToggle={(enable) =>
        void inEveryScope((scope) =>
          toggle(scope, group.kind, group.name, enable),
        )
      }
      onSwitchVersion={switchTo}
      onCompare={compare}
      onFollow={follow}
      onReload={reload}
    />
  );

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <PackageHeader
        kind={group.kind}
        displayName={displayName}
        description={group.description}
        forked={meta?.fork != null}
        mark={mark}
        action={
          <PackageActions
            scope={primary.scope}
            kind={group.kind}
            name={group.name}
            primaryPath={primary.path}
            updateAvailable={canUpdate}
            previewAvailable={newer && installed != null}
            withheldNote={updateWithheld}
            busy={mutating}
            onUpdate={() => latest && updateToLatest(latest)}
            onPreview={() => latest && compare(latest)}
            onDelete={() => setConfirmDelete(true)}
          />
        }
      />
      <PackageTabs
        kind={group.kind}
        name={group.name}
        scope={ref.scope}
        scopes={groupScopes(group)}
        vendor={vendorAt(group.installations, ref.scope)}
        harnesses={group.harnesses as HarnessId[]}
        busy={mutating}
        onDelete={() => setConfirmDelete(true)}
        body={body}
      />
      {dirty ? (
        <SaveBar
          saving={saving}
          busy={mutating}
          onSave={() => void save()}
          onDiscard={() => void load()}
        />
      ) : null}
      <DeleteDialog
        open={confirmDelete}
        onOpenChange={setConfirmDelete}
        kind={group.kind}
        name={group.name}
        scopes={groupScopes(group)}
        onGone={back}
      />
    </div>
  );
}
