import { useState } from "react";
import type { DriftRow, HarnessId, ItemKind } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { KindHarnessChips } from "@/components/kind-harness-chips";
import { Button } from "@/components/ui/button";
import {
  IN_THE_WAY_BODY,
  KEEP_FILES_CONFIRM_LABEL,
  KEEP_FILES_CONSEQUENCE,
  KEEP_FILES_LABEL,
  keepFilesConfirmBody,
  keepFilesConfirmTitle,
  MOVE_FILES_YOURSELF,
  REPLACE_FILES_CONFIRM_LABEL,
  REPLACE_FILES_CONSEQUENCE,
  REPLACE_FILES_LABEL,
  replaceFilesConfirmBody,
  replaceFilesConfirmTitle,
} from "@/lib/copy-in-the-way";
import { type MergedDriftRow, summarizePaths } from "@/lib/drift-merge";

/** Which exit a row is waiting on a confirmation for. */
type Pending = { group: MergedDriftRow; exit: "keep" | "replace" };

/**
 * Items kendex.toml asks for whose files were already on disk. Both ways
 * out live on the row a person is reading: keeping the files hands them to
 * kendex as they are, replacing them installs what was asked for and sends
 * the old copies to the trash. Neither is safe to guess, and the plan
 * cannot move until one is picked — which is why this sits with the other
 * decisions rather than under the Apply button, which cannot move it.
 *
 * A bordered box with the explainer as its header strip, the shape its
 * neighbour in the zone already has — so the sentence belongs to the rows
 * under it rather than to the zone, which also holds findings about files
 * kendex did write. No heading of its own: the zone's is the only one.
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
    harnesses: HarnessId[],
  ) => Promise<unknown>;
  onReplace: (kind: DriftRow["kind"], name: string) => Promise<unknown>;
}) {
  const [pending, setPending] = useState<Pending | null>(null);
  if (rows.length === 0) return null;

  const where = (group: MergedDriftRow) =>
    summarizePaths(group.installations.map((row) => row.detail));

  // One row is one item however many tools it targets, and its tools are
  // handed over together: one at a time, each tool's copy landed on top of
  // the last and the declaration kept only the first.
  const confirm = () => {
    if (!pending) return;
    const { group, exit } = pending;
    const harnesses = [
      ...new Set(group.installations.map((row) => row.harness)),
    ];
    if (exit === "keep") void onKeep(group.kind, group.name, harnesses);
    else void onReplace(group.kind, group.name);
    setPending(null);
  };

  return (
    <div className="overflow-hidden rounded-lg border">
      <p className="border-b bg-muted/40 px-3 py-2 text-[13px] text-foreground/75">
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
              className="flex flex-wrap items-start gap-3 px-3 py-3"
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
                <KindHarnessChips kind={group.kind} harnesses={harnesses} />
              </span>
              {/* Each exit says what it does, under the control that does
                  it — a row with no Keep button then carries only the line
                  telling the reader how to keep the files themselves. */}
              <div className="flex shrink-0 flex-wrap items-start gap-4">
                {adoptable.includes(group.kind) ? (
                  <Exit
                    consequence={KEEP_FILES_CONSEQUENCE}
                    control={
                      <Button
                        size="sm"
                        disabled={busy}
                        onClick={() => setPending({ group, exit: "keep" })}
                      >
                        {KEEP_FILES_LABEL}
                      </Button>
                    }
                  />
                ) : (
                  <span className="max-w-[16rem] text-[13px] text-muted-foreground">
                    {MOVE_FILES_YOURSELF}
                  </span>
                )}
                <Exit
                  consequence={REPLACE_FILES_CONSEQUENCE}
                  control={
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={busy}
                      onClick={() => setPending({ group, exit: "replace" })}
                    >
                      {REPLACE_FILES_LABEL}
                    </Button>
                  }
                />
              </div>
            </div>
          );
        })}
      </div>
      <ConfirmDialog
        open={pending != null}
        onOpenChange={(open) => {
          if (!open) setPending(null);
        }}
        title={
          pending?.exit === "keep"
            ? keepFilesConfirmTitle(pending.group.name)
            : replaceFilesConfirmTitle(pending?.group.name ?? "")
        }
        description={
          pending?.exit === "keep"
            ? keepFilesConfirmBody(alsoApplies)
            : replaceFilesConfirmBody(
                (pending && where(pending.group)?.text) ?? "",
                alsoApplies,
              )
        }
        confirmLabel={
          pending?.exit === "keep"
            ? KEEP_FILES_CONFIRM_LABEL
            : REPLACE_FILES_CONFIRM_LABEL
        }
        destructive={pending?.exit === "replace"}
        busy={busy}
        onConfirm={confirm}
      />
    </div>
  );
}

/** One way out: the control, and under it what taking it does. */
function Exit({
  control,
  consequence,
}: {
  control: React.ReactNode;
  consequence: string;
}) {
  return (
    <span className="flex max-w-[16rem] flex-col items-start gap-1">
      {control}
      <span className="text-[13px] text-muted-foreground">{consequence}</span>
    </span>
  );
}
