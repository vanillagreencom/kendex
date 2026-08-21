import { useEffect, useMemo, useState } from "react";
import type { HarnessId, Scope, VersionRow } from "@/bindings";
import { ItemCustomize } from "@/components/customize/item-customize";
import { SaveBar } from "@/components/customize/save-bar";
import { PackageActions } from "@/components/package/package-actions";
import { PackageBody } from "@/components/package/package-body";
import { PackageHeader } from "@/components/package/package-header";
import { RemoveDialog } from "@/components/package/remove-dialog";
import {
  diffHarness,
  type PackageView,
  packageVersionActions,
  useManifestBusy,
  usePackageData,
  usePackageDiff,
} from "@/components/package/use-package-data";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { CUSTOMIZE_TAB, OVERVIEW_TAB } from "@/lib/copy-customize";
import {
  canCustomize,
  isCustomized,
  itemCustomization,
} from "@/lib/customization";
import { groupItems, groupScopes } from "@/lib/derive";
import { packageDisplayName } from "@/lib/labels";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { sameScope } from "@/lib/scope";
import { cn } from "@/lib/utils";
import { installedRow, latestRow, versionRowLabel } from "@/lib/versions";
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
  const { draft, dirty, saving, openScope, load, save } = useEditorStore();

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
  const [confirmRemove, setConfirmRemove] = useState(false);
  const [switching, setSwitching] = useState(false);
  const mutating = useManifestBusy(switching);
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

  const { meta, files, versions, load: reload } = usePackageData(ref);
  const diff = usePackageDiff(
    ref,
    view,
    diffHarness(view, group?.installations[0]?.harness ?? null),
  );
  const updatesLoaded = useUpdatesStore((s) => s.loaded);
  const edited = useUpdatesStore((s) =>
    s.rows.some(
      (row) =>
        ref != null &&
        row.kind === ref.kind &&
        row.name === ref.name &&
        sameScope(row.scope, ref.scope) &&
        row.blockedByLocalEdit,
    ),
  );

  // The scan no longer knows this package (removed, renamed): leave the
  // way the user came.
  useEffect(() => {
    if (ref && result && !group) back();
  }, [ref, result, group, back]);

  if (!ref || !group) return null;
  const primary = group.installations[0];
  if (!primary) return null;

  const displayName = packageDisplayName(ref);
  const installed = installedRow(versions);
  const latest = latestRow(versions);
  // Update waits for meta (held vs following) and the updates store
  // (edited), and is off while edits are held.
  const canUpdate =
    latest != null &&
    !latest.installed &&
    installed != null &&
    meta != null &&
    updatesLoaded &&
    !edited;
  const customizable = canCustomize(group.kind);
  const customized = isCustomized(
    itemCustomization(draft, group.kind, group.name),
  );

  const inEveryScope = async (act: (scope: Scope) => Promise<void>) => {
    for (const scope of groupScopes(group)) await act(scope);
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
        customized={customized}
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
          {customizable ? (
            <Tabs defaultValue="overview">
              <TabsList>
                <TabsTrigger value="overview">{OVERVIEW_TAB}</TabsTrigger>
                <TabsTrigger value="customize">{CUSTOMIZE_TAB}</TabsTrigger>
              </TabsList>
              <TabsContent value="overview" className="pt-6">
                {body}
              </TabsContent>
              <TabsContent value="customize" className="pt-6">
                <ItemCustomize
                  kind={group.kind}
                  name={group.name}
                  scopes={groupScopes(group)}
                  harnesses={group.harnesses as HarnessId[]}
                />
              </TabsContent>
            </Tabs>
          ) : (
            body
          )}
        </div>
      </div>
      {dirty ? (
        <SaveBar
          saving={saving}
          onSave={() => void save()}
          onDiscard={() => void load()}
        />
      ) : null}
      <RemoveDialog
        open={confirmRemove}
        onOpenChange={setConfirmRemove}
        kind={group.kind}
        name={group.name}
        scopes={groupScopes(group)}
        onGone={back}
      />
    </div>
  );
}
