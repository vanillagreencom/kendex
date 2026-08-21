import { useState } from "react";
import type { DriftRow, ItemKind } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { KindHarnessChips } from "@/components/kind-harness-chips";
import { Button } from "@/components/ui/button";
import {
  IN_THE_WAY_BODY,
  KEEP_FILES_LABEL,
  MOVE_FILES_YOURSELF,
  REPLACE_FILES_CONFIRM_LABEL,
  REPLACE_FILES_LABEL,
  replaceFilesConfirmBody,
  replaceFilesConfirmTitle,
} from "@/lib/copy-in-the-way";
import { type MergedDriftRow, summarizePaths } from "@/lib/drift-merge";

/**
 * Items kendex.toml asks for whose files were already on disk. Both ways
 * out live on the row a person is reading: keeping the files hands them to
 * kendex as they are, replacing them installs what was asked for and sends
 * the old copies to the trash. Neither is safe to guess, and the plan
 * cannot move until one is picked — which is why this sits with the other
 * decisions rather than under the Apply button, which cannot move it.
 *
 * No heading of its own: its two neighbours in that zone have none either,
 * and a second heading at the same size as the zone's own would leave
 * everything below it reading as part of this one group.
 */
export function BlockedDeclarations({
  rows,
  adoptable,
  alsoApplies,
  busy,
  onKeep,
  onReplace,
}: {
  rows: MergedDriftRow[];
  /** The kinds "keep these files" works for, from core's own list. */
  adoptable: ItemKind[];
  /** Whether this project has other changes waiting, which the same apply
   *  carries — every apply is the whole scope's. */
  alsoApplies: boolean;
  busy: boolean;
  onKeep: (
    kind: DriftRow["kind"],
    name: string,
    harness: DriftRow["harness"],
    opts?: { silent?: boolean },
  ) => Promise<boolean>;
  onReplace: (kind: DriftRow["kind"], name: string) => Promise<unknown>;
}) {
  const [confirming, setConfirming] = useState<MergedDriftRow | null>(null);
  if (rows.length === 0) return null;

  // One row is one item however many tools it targets, and every apply
  // takes the scope's writer lock — so its installations are handed over
  // one at a time, only the first speaks up, and the first failure stops
  // the rest: after one has failed, the others are answering a question
  // the page can no longer see.
  const keepAll = async (group: MergedDriftRow) => {
    let index = 0;
    for (const row of group.installations) {
      const ok = await onKeep(row.kind, row.name, row.harness, {
        silent: index > 0,
      });
      if (!ok) return;
      index += 1;
    }
  };

  const where = (group: MergedDriftRow) =>
    summarizePaths(group.installations.map((row) => row.detail));

  return (
    <div className="flex flex-col gap-2">
      <p className="max-w-prose text-[13px] text-muted-foreground">
        {IN_THE_WAY_BODY}
      </p>
      <div className="divide-y divide-border/60">
        {rows.map((group) => {
          const paths = where(group);
          const harnesses = [
            ...new Set(group.installations.map((row) => row.harness)),
          ];
          return (
            <div
              key={`${group.kind}:${group.name}`}
              className="flex flex-wrap items-center gap-3 py-2.5 first:pt-0 last:pb-0"
            >
              <span className="flex min-w-0 flex-1 flex-col gap-1">
                <span className="truncate text-sm font-medium">
                  {group.name}
                </span>
                {paths ? (
                  <span
                    className="truncate font-mono text-xs text-muted-foreground"
                    title={paths.title}
                  >
                    {paths.text}
                  </span>
                ) : null}
              </span>
              <KindHarnessChips kind={group.kind} harnesses={harnesses} />
              <div className="flex shrink-0 items-center gap-2">
                {adoptable.includes(group.kind) ? (
                  <Button
                    size="sm"
                    disabled={busy}
                    onClick={() => void keepAll(group)}
                  >
                    {KEEP_FILES_LABEL}
                  </Button>
                ) : (
                  <span className="text-[13px] text-muted-foreground">
                    {MOVE_FILES_YOURSELF}
                  </span>
                )}
                <Button
                  size="sm"
                  variant="outline"
                  disabled={busy}
                  onClick={() => setConfirming(group)}
                >
                  {REPLACE_FILES_LABEL}
                </Button>
              </div>
            </div>
          );
        })}
      </div>
      <ConfirmDialog
        open={confirming != null}
        onOpenChange={(open) => {
          if (!open) setConfirming(null);
        }}
        title={replaceFilesConfirmTitle(confirming?.name ?? "")}
        description={replaceFilesConfirmBody(
          (confirming && where(confirming)?.title) ?? "",
          alsoApplies,
        )}
        confirmLabel={REPLACE_FILES_CONFIRM_LABEL}
        destructive
        busy={busy}
        onConfirm={() => {
          if (confirming) void onReplace(confirming.kind, confirming.name);
          setConfirming(null);
        }}
      />
    </div>
  );
}
