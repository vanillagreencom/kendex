import { useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import type { HarnessId, Scope, VersionRow } from "@/bindings";
import { ItemCustomize } from "@/components/customize/item-customize";
import { SaveBar } from "@/components/customize/save-bar";
import { UnsavedElsewhere } from "@/components/customize/unsaved-elsewhere";
import { MarksNote } from "@/components/marks-note";
import { PackageActions } from "@/components/package/package-actions";
import { PackageBody } from "@/components/package/package-body";
import { PackageHeader } from "@/components/package/package-header";
import { PackageTabs } from "@/components/package/package-tabs";
import { RemoveDialog } from "@/components/package/remove-dialog";
import {
  diffHarness,
  openingTab,
  openingView,
  type PackageView,
  packageVersionActions,
  useManifestBusy,
  usePackageData,
  usePackageDiff,
} from "@/components/package/use-package-data";
import { packageGoneHere } from "@/lib/copy";
import { canCustomize } from "@/lib/customization";
import { groupItems, groupScopes } from "@/lib/derive";
import { packageDisplayName, scopeName, scopePath } from "@/lib/labels";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { packageMarks } from "@/lib/place-marks";
import { useEditingPlacesSource } from "@/lib/places-source";
import { cn } from "@/lib/utils";
import { installedRow, latestRow, versionRowLabel } from "@/lib/versions";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { inEveryPlace } from "@/stores/unsaved-first";
import { canApplyUpdates, useUpdatesStore } from "@/stores/updates";

/** One package, full page: what it is as installed, and what you have
 *  changed about it. */
export function PackagePage() {
  const ref = useNavStore((s) => s.packageRef);
  const initialView = useNavStore((s) => s.packageView);
  const clearPackageView = useNavStore((s) => s.clearPackageView);
  const back = useNavStore((s) => s.back);
  const result = useScanStore((s) => s.result);
  const toggle = useAuditStore((s) => s.toggle);
  const { dirty, saving, openScope, discard, save } = useEditorStore();
  const places = useEditingPlacesSource();

  const [view, setView] = useState<PackageView>(() => openingView(initialView));
  const [tab, setTab] = useState(() => openingTab(initialView));
  const [confirmRemove, setConfirmRemove] = useState(false);
  const mutating = useManifestBusy();
  useEffect(() => {
    if (initialView) clearPackageView();
  }, [initialView, clearPackageView]);

  // The Customize tab opens on the place this page is about; its chips move
  // the editor from there, and nothing this page says follows them.
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

  const { meta, files, versions, load: reload } = usePackageData(ref);
  // Everything this page says is about one place: the one it was opened at,
  // which a customized mark can name any of. Its installation carries the
  // path, the open actions, the broken-link state and the tool a comparison
  // reads; the standing carries the header's badges; the row carries the
  // edited-files notice.
  const { primary, selected, editedRow } =
    group && ref
      ? packageMarks(places, group, ref.scope)
      : { primary: null, selected: null, editedRow: null };
  const diff = usePackageDiff(
    ref,
    view,
    diffHarness(view, primary?.harness ?? null),
  );
  const updatesCurrent = useUpdatesStore(canApplyUpdates);

  // The scan no longer knows this package here — removed from this project,
  // renamed, or nav state that outlived the scope. Going back can land on
  // the very row that was clicked, so the way out says why rather than
  // looking like a click that did nothing.
  useEffect(() => {
    if (!ref || !result || primary) return;
    toast.info(packageGoneHere(scopePath(ref.scope) ?? scopeName(ref.scope)));
    back();
  }, [ref, result, primary, back]);

  if (!ref || !group || !primary) return null;

  const displayName = packageDisplayName(ref);
  const installed = installedRow(versions);
  const latest = latestRow(versions);
  const customizable = canCustomize(group.kind);
  const scopes = groupScopes(group);
  // Update waits for meta (held vs following) and the update standing, and
  // is off while edits are held. A check still on its way means the newest
  // version on screen is the one before it: the button applies the revision
  // this read named, so it waits for the read that names it.
  const canUpdate =
    latest != null &&
    !latest.installed &&
    installed != null &&
    meta != null &&
    updatesCurrent &&
    editedRow == null;

  const inEveryScope = (act: (scope: Scope) => Promise<boolean>) =>
    inEveryPlace(scopes, act);

  const { switchTo, updateToLatest, follow } = packageVersionActions(
    ref,
    displayName,
    meta?.rev != null,
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
      editedRow={editedRow}
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
        place={selected}
        scopes={scopes}
        action={
          <PackageActions
            scope={primary.scope}
            kind={group.kind}
            name={group.name}
            primaryPath={primary.path}
            updateAvailable={canUpdate}
            busy={mutating}
            onUpdate={() => latest && updateToLatest(latest)}
            onPreview={() => latest && compare(latest)}
            onRemove={() => setConfirmRemove(true)}
          />
        }
      />
      <div className={cn("min-h-0 flex-1 overflow-y-auto", PAGE_GUTTER)}>
        <div className={cn("pb-8", WIDE_CONTENT_WIDTH)}>
          {/* The marks in the header and on the chips rest on the same two
              reads the Library's do, so a failure has to be sayable here
              too — this is where someone comes to act on one. */}
          <MarksNote className="mt-3" />
          {/* Typing left at another place travels rather than being
              dropped, so it is named here — above the tabs, since arriving
              on Overview must not hide it. */}
          <UnsavedElsewhere className="mt-3" />
          <PackageTabs
            customizable={customizable}
            tab={tab}
            onTabChange={setTab}
            overview={body}
            customize={
              <ItemCustomize
                kind={group.kind}
                name={group.name}
                scopes={scopes}
                harnesses={group.harnesses as HarnessId[]}
              />
            }
          />
        </div>
      </div>
      {dirty ? (
        <SaveBar
          saving={saving}
          busy={mutating}
          onSave={() => void save()}
          onDiscard={() => void discard()}
        />
      ) : null}
      <RemoveDialog
        open={confirmRemove}
        onOpenChange={setConfirmRemove}
        kind={group.kind}
        name={group.name}
        scopes={scopes}
        onGone={back}
      />
    </div>
  );
}
