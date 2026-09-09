import type {
  HarnessId,
  ObservedItem,
  PackageMeta_Serialize,
  VersionRow,
} from "@/bindings";
import { FilePreview } from "@/components/package/file-preview";
import { EditedNotice } from "@/components/package/fork-notice";
import { PackageDetails } from "@/components/package/package-details";
import type { ItemGroup } from "@/lib/derive";
import type { PackageRef } from "@/stores/nav";

/** What a package is, read top to bottom: where it came from, whether your
 *  harnesses load it, which version is installed — and then the package's
 *  own words about itself. Its files are a tab of their own, where the
 *  tree has the width to show the shape of the package. */
export function PackageOverview({
  reference,
  group,
  primary,
  meta,
  versions,
  busy,
  declares,
  onToggle,
  onSwitchVersion,
  onCompare,
  onCompareEdits,
  onFollow,
  onReload,
}: {
  reference: PackageRef;
  group: ItemGroup;
  primary: ObservedItem;
  meta: PackageMeta_Serialize | null;
  versions: VersionRow[];
  busy: boolean;
  /** Whether this page addresses a declaration. Everything here that reads
   *  or writes by scope, kind and name speaks to whatever package the
   *  records hold under that address, which on a page about an
   *  installation nothing recorded is a different thing than it describes. */
  declares: boolean;
  /** Absent where this page addresses no declaration — the switch writes
   *  one, and there is none behind an installation nothing recorded. */
  onToggle?: (enable: boolean) => void;
  onSwitchVersion: (row: VersionRow) => void;
  onCompare: (row: VersionRow) => void;
  /** Show what this person changed about the installed copy, in the tool
   *  the notice named. */
  onCompareEdits: (harness?: HarnessId) => void;
  onFollow: () => void;
  onReload: () => void;
}) {
  return (
    <div className="flex max-w-3xl flex-col gap-8">
      {/* A hand edit is an edit to a declared package's copy, and the
          notice offers to keep it as a fork or discard it — both writes to
          that declaration. There is none behind an observed row. */}
      {declares ? (
        <EditedNotice
          scope={reference.scope}
          kind={reference.kind}
          name={reference.name}
          alreadyForked={meta?.fork != null}
          onViewChanges={onCompareEdits}
          onResolved={onReload}
        />
      ) : null}
      <PackageDetails
        group={group}
        primary={primary}
        meta={meta}
        versions={versions}
        busy={busy}
        onToggle={onToggle}
        onSwitchVersion={onSwitchVersion}
        onCompare={onCompare}
        onFollow={onFollow}
      />
      {/* The preview reads a package's files by scope, kind and name —
          the declaration's address. An observed row has no declaration to
          read, and asking anyway would show the other package's bytes
          under this one's name. */}
      {declares ? (
        <FilePreview
          scope={reference.scope}
          kind={reference.kind}
          name={reference.name}
          path={null}
        />
      ) : null}
    </div>
  );
}
