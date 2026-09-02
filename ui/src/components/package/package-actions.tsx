import { ExternalLink } from "lucide-react";
import { commands, type ItemKind, type Scope } from "@/bindings";
import { ReportDialog } from "@/components/report-dialog";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  EDITOR_ERROR_STEPS,
  EDITOR_ERROR_TITLE,
  FILE_BROWSER_ERROR_TITLE,
  OPEN_IN_EDITOR_LABEL,
  OPEN_IN_FILE_BROWSER_LABEL,
  OPEN_IN_LABEL,
  PREVIEW_CHANGES_LABEL,
  TRY_AGAIN_LABEL,
  UPDATE_LABEL,
} from "@/lib/copy";
import { DELETE_LABEL } from "@/lib/copy-projects";
import { UPDATES_ONE_AT_A_TIME_NOTE } from "@/lib/copy-updates";
import { editorOpenPath } from "@/lib/editor-path";
import { useProblemsStore } from "@/stores/problems";
import { useUpdatesStore } from "@/stores/updates";
import { useVersionsBusy } from "./use-package-data";

/** The package page's header actions: update when a newer version exists,
 *  the open-in menu, delete, and report. */
export function PackageActions({
  scope,
  kind,
  name,
  primaryPath,
  updateAvailable,
  previewAvailable,
  withheldNote,
  onRetryRead,
  retryRunning,
  busy,
  onUpdate,
  onPreview,
  onDelete,
}: {
  scope: Scope;
  kind: ItemKind;
  name: string;
  primaryPath: string;
  updateAvailable: boolean;
  /** Whether there are two versions to diff: a newest that is not the
   *  installed one, and an installed one to compare it against. A package
   *  already at its newest has one version, and a diff of a commit with
   *  itself is an empty comparison to close rather than something to read.
   *  Read-only otherwise, so no state of the update read bears on it — a
   *  check in flight or a refusal to write does not stop anyone looking at
   *  what changed. */
  previewAvailable: boolean;
  /** Why there is no Update here, already ranked: `versions.ts`
   *  [`updateOffer`] picks it and owns the order. Rendered whenever
   *  `updateAvailable` is false and this is set. The page has other reasons
   *  to offer nothing, an unmappable installed commit among them, and those
   *  it does not word. */
  withheldNote?: string | null;
  /** Read this package again, set only where the note above is one reading
   *  again can lift. */
  onRetryRead?: () => void;
  /** Whether that read is out right now. The note stays put while it runs —
   *  it is still the last answer — so the button is what says the page is
   *  doing something about it. */
  retryRunning?: boolean;
  busy: boolean;
  onUpdate: () => void;
  onPreview: () => void;
  onDelete: () => void;
}) {
  const showError = useProblemsStore((s) => s.showError);
  // Update commits through the updates store, so it also waits on a check;
  // Delete beside it goes another way and does not. The check's half is
  // the one this surface can name — the rest is the page's own manifest
  // work, which says so where it started.
  const updating = useVersionsBusy(busy);
  const waiting = useUpdatesStore((s) => s.checking);

  const openInFileBrowser = () => {
    void commands.revealPath(primaryPath).then((response) => {
      if (response.status === "error") {
        showError({ title: FILE_BROWSER_ERROR_TITLE, message: response.error });
      }
    });
  };

  const openInEditor = () => {
    void commands.openInEditor(editorOpenPath(primaryPath)).then((response) => {
      if (response.status === "error") {
        showError({
          title: EDITOR_ERROR_TITLE,
          message: response.error,
          steps: EDITOR_ERROR_STEPS,
        });
      }
    });
  };

  return (
    <div className="flex flex-wrap items-center gap-2">
      {updateAvailable ? (
        <Button
          size="sm"
          disabled={updating}
          title={waiting ? UPDATES_ONE_AT_A_TIME_NOTE : undefined}
          onClick={onUpdate}
        >
          {UPDATE_LABEL}
        </Button>
      ) : null}
      {previewAvailable ? (
        <Button size="sm" variant="outline" onClick={onPreview}>
          {PREVIEW_CHANGES_LABEL}
        </Button>
      ) : null}
      {!updateAvailable && withheldNote ? (
        <div className="flex items-center gap-2">
          <p className="text-sm text-muted-foreground">{withheldNote}</p>
          {/* A read that failed shows its error with a way to run it
              again; a reason no read can lift shows the reason alone. */}
          {onRetryRead ? (
            <Button
              size="sm"
              variant="outline"
              disabled={retryRunning}
              onClick={onRetryRead}
            >
              {TRY_AGAIN_LABEL}
            </Button>
          ) : null}
        </div>
      ) : null}
      <DropdownMenu>
        <DropdownMenuTrigger
          render={
            <Button size="sm" variant="outline">
              <ExternalLink className="size-4" />
              {OPEN_IN_LABEL}
            </Button>
          }
        />
        <DropdownMenuContent>
          <DropdownMenuItem onClick={openInFileBrowser}>
            {OPEN_IN_FILE_BROWSER_LABEL}
          </DropdownMenuItem>
          <DropdownMenuItem onClick={openInEditor}>
            {OPEN_IN_EDITOR_LABEL}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      {/* Named for what it does: this takes every copy of the package,
          in every place, not the one place the page names. */}
      <Button size="sm" variant="outline" disabled={busy} onClick={onDelete}>
        {DELETE_LABEL}
      </Button>
      <ReportDialog scope={scope} name={name} kind={kind} />
    </div>
  );
}
