import { useState } from "react";
import type { DriftRow } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { KindHarnessChips } from "@/components/kind-harness-chips";
import { Section } from "@/components/section";
import { Button } from "@/components/ui/button";
import {
  IN_THE_WAY_BODY,
  IN_THE_WAY_TITLE,
  KEEP_FILES_HINT,
  KEEP_FILES_LABEL,
  REPLACE_FILES_CONFIRM_BODY,
  REPLACE_FILES_CONFIRM_LABEL,
  REPLACE_FILES_HINT,
  REPLACE_FILES_LABEL,
  replaceFilesConfirmTitle,
} from "@/lib/copy";
import type { MergedDriftRow } from "@/lib/drift-merge";

/**
 * Items you asked for whose files were already on disk. Both ways out live
 * on the row a person is reading: keeping the files hands them to kendex as
 * they are, replacing them installs what was asked for and sends the old
 * copies to the trash. Neither one is safe to guess, and the plan cannot
 * move until one of them is picked — which is why this sits above the
 * changes the Apply button covers rather than inside them.
 */
export function BlockedDeclarations({
  rows,
  busy,
  onKeep,
  onReplace,
}: {
  rows: MergedDriftRow[];
  busy: boolean;
  onKeep: (
    kind: DriftRow["kind"],
    name: string,
    harness: DriftRow["harness"],
    opts?: { silent?: boolean },
  ) => void | Promise<void>;
  onReplace: (kind: DriftRow["kind"], name: string) => void | Promise<void>;
}) {
  const [confirming, setConfirming] = useState<MergedDriftRow | null>(null);
  if (rows.length === 0) return null;

  // One row is one item however many tools it targets, and every apply
  // takes the scope's writer lock — so its installations are handed over
  // one at a time, and only the first speaks up.
  const keepAll = async (group: MergedDriftRow) => {
    let index = 0;
    for (const row of group.installations) {
      await onKeep(row.kind, row.name, row.harness, { silent: index > 0 });
      index += 1;
    }
  };

  return (
    <Section title={IN_THE_WAY_TITLE} description={IN_THE_WAY_BODY}>
      <div className="divide-y divide-border/60 rounded-lg border bg-muted/30">
        {rows.map((group) => {
          // Which files, in full, without a wall of mono paths on a row
          // whose job is the choice: the engine's sentence per tool, on
          // hover, exactly as the CLI prints it.
          const where = group.installations.map((row) => row.detail).join("\n");
          const harnesses = [
            ...new Set(group.installations.map((row) => row.harness)),
          ];
          return (
            <div
              key={`${group.kind}:${group.name}`}
              className="flex flex-wrap items-center gap-3 px-3 py-3"
            >
              <span
                className="min-w-0 flex-1 truncate text-sm font-medium"
                title={where}
              >
                {group.name}
              </span>
              <KindHarnessChips kind={group.kind} harnesses={harnesses} />
              <div className="flex shrink-0 items-center gap-2">
                <Button
                  size="sm"
                  disabled={busy}
                  title={KEEP_FILES_HINT}
                  onClick={() => void keepAll(group)}
                >
                  {KEEP_FILES_LABEL}
                </Button>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={busy}
                  title={REPLACE_FILES_HINT}
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
        description={REPLACE_FILES_CONFIRM_BODY}
        confirmLabel={REPLACE_FILES_CONFIRM_LABEL}
        destructive
        busy={busy}
        onConfirm={() => {
          if (confirming) void onReplace(confirming.kind, confirming.name);
          setConfirming(null);
        }}
      />
    </Section>
  );
}
