import { ConfirmDialog } from "@/components/confirm-dialog";
import {
  SAVE_CONFIRM_ACTION,
  SAVE_CONFIRM_DESCRIPTION,
  SAVE_CONFIRM_EMPTY,
  SAVE_CONFIRM_SECRET_NOTE,
  SAVE_CONFIRM_TITLE,
} from "@/lib/copy-customize";
import type { SaveGroup } from "@/lib/save-summary";

/**
 * Every file a save is about to write, before it writes one.
 *
 * The list is built from the reads the fields came from, and it is
 * refreshed as this opens: a project pointed at another private file
 * between typing and saving would otherwise be confirmed against the file
 * it used to have. Cancel writes nothing and keeps the draft.
 *
 * Keys are named and values are not, secrets included — a person opens
 * this to check where a credential is going, not to see it again.
 */
export function SaveConfirm({
  open,
  groups,
  saving,
  hasSecrets,
  onOpenChange,
  onConfirm,
}: {
  open: boolean;
  groups: SaveGroup[];
  saving: boolean;
  /** Whether any credential is in this save, which is the one thing the
   *  note below is about. */
  hasSecrets: boolean;
  onOpenChange: (open: boolean) => void;
  onConfirm: () => void;
}) {
  return (
    <ConfirmDialog
      open={open}
      onOpenChange={onOpenChange}
      title={SAVE_CONFIRM_TITLE}
      description={SAVE_CONFIRM_DESCRIPTION}
      confirmLabel={SAVE_CONFIRM_ACTION}
      busy={saving}
      onConfirm={onConfirm}
    >
      {groups.length === 0 ? (
        <p className="text-[13px] text-muted-foreground">
          {SAVE_CONFIRM_EMPTY}
        </p>
      ) : (
        <ul className="flex flex-col gap-2">
          {groups.map((group) => (
            <li key={group.file} className="flex flex-col gap-0.5">
              <code className="font-mono text-[13px]">{group.file}</code>
              <span className="text-[13px] text-muted-foreground">
                {group.labels.join(", ")}
              </span>
            </li>
          ))}
        </ul>
      )}
      {hasSecrets ? (
        <p className="text-xs text-muted-foreground">
          {SAVE_CONFIRM_SECRET_NOTE}
        </p>
      ) : null}
    </ConfirmDialog>
  );
}
