import { useState } from "react";
import { toast } from "sonner";
import { commands } from "@/bindings";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  COPY_PATH_LABEL,
  EDITOR_ERROR_STEPS,
  EDITOR_ERROR_TITLE,
  FILE_BROWSER_ERROR_TITLE,
  OPEN_IN_EDITOR_LABEL,
  OPEN_IN_FILE_BROWSER_LABEL,
  PATH_COPIED_TOAST,
} from "@/lib/copy";
import { abbreviateHome } from "@/lib/drift-merge";
import { editorOpenPath } from "@/lib/editor-path";
import { useProblemsStore } from "@/stores/problems";

/** Where a finding fired: a file, and the line within it when it has one. */
export type Place = { file: string; line: number | null };

/**
 * A file a finding points at, as something you can act on rather than a
 * path to read and retype. It reads as code — that is what it is — and
 * opens where the file can actually be looked at.
 *
 * `file:line` is composed here and nowhere before it. Carrying the two as
 * one string would mean every reader splitting it back, and no split is
 * right for a file whose own name ends in a colon and digits.
 */
export function FileLink({ place }: { place: Place }) {
  const showError = useProblemsStore((s) => s.showError);
  const [open, setOpen] = useState(false);
  const file = place.file;
  const location = place.line === null ? file : `${file}:${place.line}`;

  const reveal = () => {
    void commands.revealPath(file).then((response) => {
      if (response.status === "error") {
        showError({ title: FILE_BROWSER_ERROR_TITLE, message: response.error });
      }
    });
  };
  const edit = () => {
    void commands.openInEditor(editorOpenPath(file)).then((response) => {
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
    <DropdownMenu open={open} onOpenChange={setOpen}>
      <DropdownMenuTrigger
        render={
          <button
            type="button"
            title={location}
            className="max-w-full truncate rounded bg-muted/70 px-1.5 py-0.5 font-mono text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
          >
            {abbreviateHome(location)}
          </button>
        }
      />
      <DropdownMenuContent>
        <DropdownMenuItem onClick={edit}>
          {OPEN_IN_EDITOR_LABEL}
        </DropdownMenuItem>
        <DropdownMenuItem onClick={reveal}>
          {OPEN_IN_FILE_BROWSER_LABEL}
        </DropdownMenuItem>
        <DropdownMenuItem
          onClick={() => {
            void navigator.clipboard.writeText(file);
            toast.success(PATH_COPIED_TOAST);
          }}
        >
          {COPY_PATH_LABEL}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
