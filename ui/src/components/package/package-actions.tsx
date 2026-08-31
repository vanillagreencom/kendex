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
  UPDATE_LABEL,
} from "@/lib/copy";
import { DELETE_LABEL } from "@/lib/copy-projects";
import { editorOpenPath } from "@/lib/editor-path";
import { useProblemsStore } from "@/stores/problems";

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
  /** Why there is no Update here, when the reason is one the update read
   *  carries: a kind core never brings current one package at a time, a
   *  read still pending or failed, a place the read never covered, an
   *  edit of the reader's own. Rendered whenever `updateAvailable` is
   *  false and this is set. The page has other reasons to offer nothing,
   *  an unmappable installed commit among them, and those it does not
   *  word. */
  withheldNote?: string | null;
  busy: boolean;
  onUpdate: () => void;
  onPreview: () => void;
  onDelete: () => void;
}) {
  const showError = useProblemsStore((s) => s.showError);

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
        <Button size="sm" disabled={busy} onClick={onUpdate}>
          {UPDATE_LABEL}
        </Button>
      ) : null}
      {previewAvailable ? (
        <Button size="sm" variant="outline" onClick={onPreview}>
          {PREVIEW_CHANGES_LABEL}
        </Button>
      ) : null}
      {!updateAvailable && withheldNote ? (
        <p className="text-sm text-muted-foreground">{withheldNote}</p>
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
