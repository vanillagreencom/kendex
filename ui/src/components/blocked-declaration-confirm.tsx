import type { HarnessId } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import {
  KEEP_FILES_CONFIRM_LABEL,
  keepFilesConfirmBody,
  keepFilesConfirmTitle,
  keepSharedConfirmBody,
  REPLACE_FILES_CONFIRM_LABEL,
  replaceFilesConfirmBody,
  replaceFilesConfirmTitle,
} from "@/lib/copy-in-the-way";
import type { MergedDriftRow } from "@/lib/drift-merge";
import { harnessName } from "@/lib/labels";

/** Which exit a row is waiting on a confirmation for. */
export type Pending = { group: MergedDriftRow; exit: "keep" | "replace" };

/** A row where every tool reads one folder through a link somebody else
 *  set up. Keeping it is a bigger move than keeping a plain folder — the
 *  folder itself goes to the trash and links kendex cannot see will break
 *  — so it gets the confirmation that names the folder and every tool. */
export const isShared = (group: MergedDriftRow) =>
  group.installations.some((row) => row.cause === "shared-link");

/**
 * What each exit asks before it runs. One action keeps its own words
 * whichever shape it takes: only what happens to the files differs, and
 * the shared folder says the more of it.
 */
export function BlockedDeclarationConfirm({
  pending,
  where,
  named,
  alsoApplies,
  busy,
  onConfirm,
  onDismiss,
}: {
  pending: Pending | null;
  where: (group: MergedDriftRow) => { text: string; count: number } | null;
  /** Every tool the row is about, which is what the sentence names — not
   *  only the ones the keep is carried out through. */
  named: (group: MergedDriftRow) => HarnessId[];
  alsoApplies: boolean;
  busy: boolean;
  onConfirm: () => void;
  onDismiss: () => void;
}) {
  const keep = (group: MergedDriftRow) => ({
    title: keepFilesConfirmTitle(group.name),
    label: KEEP_FILES_CONFIRM_LABEL,
    body: isShared(group)
      ? keepSharedConfirmBody(
          where(group)?.text ?? "",
          named(group).map(harnessName),
          alsoApplies,
        )
      : keepFilesConfirmBody(alsoApplies),
  });

  return (
    <ConfirmDialog
      open={pending != null}
      onOpenChange={(open) => {
        if (!open) onDismiss();
      }}
      title={
        pending?.exit === "keep"
          ? keep(pending.group).title
          : replaceFilesConfirmTitle(pending?.group.name ?? "")
      }
      description={
        pending?.exit === "keep"
          ? keep(pending.group).body
          : replaceFilesConfirmBody(
              (pending && where(pending.group)?.text) ?? "",
              (pending && where(pending.group)?.count) ?? 0,
              alsoApplies,
            )
      }
      confirmLabel={
        pending?.exit === "keep"
          ? keep(pending.group).label
          : REPLACE_FILES_CONFIRM_LABEL
      }
      destructive={
        // A shared folder goes to the trash whole and shortcuts kendex
        // cannot see break with it, which the body says — so keeping it is
        // weighted like the replacement, and like the Library weighs the
        // same move.
        pending?.exit === "replace" || (!!pending && isShared(pending.group))
      }
      busy={busy}
      onConfirm={onConfirm}
    />
  );
}
