import type {
  ObservedItem,
  PackageMeta_Serialize,
  VersionRow,
} from "@/bindings";
import { PackageMetaBlock } from "@/components/package/package-meta";
import { VersionMenu } from "@/components/package/version-menu";
import { SectionHeading, SettingRow } from "@/components/section";
import { Switch } from "@/components/ui/switch";
import { ENABLED_HELP, ENABLED_LABEL, PACKAGE_VERSION_TITLE } from "@/lib/copy";
import type { ItemGroup } from "@/lib/derive";

/** What a package is and the two things you can settle about it here:
 *  where it came from, whether your harnesses load it, and which version
 *  is installed. The Overview opens on this, and the package's own README
 *  reads underneath it. */
export function PackageDetails({
  group,
  primary,
  meta,
  versions,
  busy,
  onToggle,
  onSwitchVersion,
  onCompare,
  onFollow,
}: {
  group: ItemGroup;
  primary: ObservedItem;
  meta: PackageMeta_Serialize | null;
  versions: VersionRow[];
  busy: boolean;
  /** Every place this package sits in is switched together, so the caller
   *  needs no scope from here. */
  /** Absent where this page addresses no declaration — the switch writes
   *  one, and there is none behind an installation nothing recorded. */
  onToggle?: (enable: boolean) => void;
  onSwitchVersion: (row: VersionRow) => void;
  onCompare: (row: VersionRow) => void;
  onFollow: () => void;
}) {
  // A switch needs a declaration to write, and a kind that has one.
  const managed =
    onToggle !== undefined &&
    (group.kind === "agent" || group.kind === "skill");
  const anyDisabled = group.installations.some((i) => i.enabled === false);
  return (
    <div className="space-y-7">
      <PackageMetaBlock group={group} primary={primary} meta={meta} />
      {managed ? (
        <SettingRow
          label={ENABLED_LABEL}
          description={ENABLED_HELP}
          htmlFor="package-enabled"
          className="border-y py-3"
        >
          <Switch
            id="package-enabled"
            checked={!anyDisabled}
            disabled={busy}
            onCheckedChange={() => onToggle?.(anyDisabled)}
          />
        </SettingRow>
      ) : null}
      {versions.length > 0 || meta?.repo ? (
        <div className="space-y-2.5">
          <SectionHeading>{PACKAGE_VERSION_TITLE}</SectionHeading>
          <VersionMenu
            versions={versions}
            held={meta?.rev != null}
            busy={busy}
            onSwitch={onSwitchVersion}
            onCompare={onCompare}
            onFollow={onFollow}
          />
        </div>
      ) : null}
    </div>
  );
}
