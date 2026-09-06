import type {
  ObservedItem,
  PackageFile,
  PackageMeta_Serialize,
  Scope,
  VersionRow,
} from "@/bindings";
import { FileList } from "@/components/package/file-list";
import { PackageMetaBlock } from "@/components/package/package-meta";
import { VersionMenu } from "@/components/package/version-menu";
import { SectionHeading, SettingRow } from "@/components/section";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import {
  ENABLED_HELP,
  ENABLED_LABEL,
  PACKAGE_FILES_TITLE,
  PACKAGE_VERSION_TITLE,
  TRY_AGAIN_LABEL,
} from "@/lib/copy";
import type { ItemGroup } from "@/lib/derive";

/** The package page's left column: details, the enabled switch, the
 *  version picker, and the file list. */
export function PackageSidebar({
  group,
  primary,
  meta,
  versions,
  files,
  filesNote,
  selectedFile,
  busy,
  retryRunning,
  onToggle,
  onSwitchVersion,
  onCompare,
  onFollow,
  onSelectFile,
  onRetryFiles,
}: {
  group: ItemGroup;
  primary: ObservedItem;
  meta: PackageMeta_Serialize | null;
  versions: VersionRow[];
  files: PackageFile[];
  /** Why there are no files to list, where the read did not land:
   *  `package-read-state.ts` [`packageFilesNote`]. Null while the read is
   *  pending or once it landed, and a landed read with nothing in it is a
   *  package that ships no files, which draws no section at all. */
  filesNote: string | null;
  selectedFile: string | null;
  busy: boolean;
  /** Whether the page's reads are out again. The note stays put while they
   *  run — it is still the last answer — so the button is what says the
   *  page is doing something about it. */
  retryRunning: boolean;
  onToggle: (scope: Scope, enable: boolean) => void;
  onSwitchVersion: (row: VersionRow) => void;
  onCompare: (row: VersionRow) => void;
  onFollow: () => void;
  onSelectFile: (path: string) => void;
  /** Read this package again, offered beside the note above. */
  onRetryFiles: () => void;
}) {
  const managed = group.kind === "agent" || group.kind === "skill";
  const anyDisabled = group.installations.some((i) => i.enabled === false);
  return (
    <div className="w-full shrink-0 space-y-7 lg:w-[24rem]">
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
            onCheckedChange={() => onToggle(primary.scope, anyDisabled)}
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
      {filesNote !== null ? (
        <div className="space-y-2.5">
          <SectionHeading>{PACKAGE_FILES_TITLE}</SectionHeading>
          <p className="text-sm text-muted-foreground">{filesNote}</p>
          <Button
            size="sm"
            variant="outline"
            disabled={retryRunning}
            onClick={onRetryFiles}
          >
            {TRY_AGAIN_LABEL}
          </Button>
        </div>
      ) : files.length > 0 ? (
        <div className="space-y-2.5">
          <SectionHeading>{PACKAGE_FILES_TITLE}</SectionHeading>
          <FileList
            files={files}
            selected={selectedFile}
            onSelect={onSelectFile}
          />
        </div>
      ) : null}
    </div>
  );
}
