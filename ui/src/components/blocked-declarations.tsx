import { useState } from "react";
import type { DriftRow, HarnessId, ItemKind } from "@/bindings";
import {
  BlockedDeclarationConfirm,
  type Pending,
} from "@/components/blocked-declaration-confirm";
import { KindHarnessChips } from "@/components/kind-harness-chips";
import { Button } from "@/components/ui/button";
import {
  IN_THE_WAY_BODY,
  KEEP_FILES_CONSEQUENCE,
  KEEP_FILES_LABEL,
  MOVE_FILES_YOURSELF,
  REPLACE_FILES_CONSEQUENCE,
  REPLACE_FILES_LABEL,
} from "@/lib/copy-in-the-way";
import { type MergedDriftRow, summarizePaths } from "@/lib/drift-merge";
import { canKeep, canReplace } from "@/lib/drift-zones";

/**
 * Items kendex.toml asks for whose files were already on disk. Both ways
 * out live on the row a person is reading: keeping the files hands them to
 * kendex as they are, replacing them installs what was asked for and sends
 * the old copies to the trash. Neither is safe to guess, and the plan
 * cannot move until one is picked — which is why this sits with the other
 * decisions rather than under the Apply button, which cannot move it.
 *
 * Not every row has both. A folder where one file goes cannot be kept as
 * it stands, and a link somebody else set up is not this position's bytes
 * to replace — so each control is drawn from what core said the position
 * allows, never from the kind alone.
 *
 * A bordered box with the explainer as its header strip, the shape its
 * neighbour in the zone already has — so the sentence belongs to the rows
 * under it rather than to the zone, which also holds findings about files
 * kendex did write. No heading of its own: the zone's is the only one.
 */
export function BlockedDeclarations({
  rows,
  adoptable,
  keepable,
  alsoApplies,
  busy,
  onKeep,
  onReplace,
}: {
  rows: MergedDriftRow[];
  /** The kinds "keep these files" works for, from core's own list. */
  adoptable: ItemKind[];
  /** The individual installations it works for, as `kind:name:harness`.
   *  Adoption works at a tool's own place, so a tool with nothing there —
   *  one reading a folder through a shortcut somebody made — cannot be the
   *  one that keeps it, and a button drawn from the cause alone would fail
   *  on the click. */
  keepable: string[];
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
  const canBeKept = new Set(keepable);
  const rowKey = (row: DriftRow) => `${row.kind}:${row.name}:${row.harness}`;
  if (rows.length === 0) return null;

  const where = (group: MergedDriftRow) =>
    summarizePaths(group.installations.map((row) => row.detail));
  // Only the tools keeping can be entered through. Adoption works at a
  // tool's own place, so one reading the item through a shortcut somebody
  // made has nothing there to take — its share is kept by the tool that
  // does hold the folder, and naming it would fail on the spot.
  const toolsOf = (group: MergedDriftRow) => [
    ...new Set(
      group.installations
        .filter((row) => canBeKept.has(rowKey(row)))
        .map((row) => row.harness),
    ),
  ];

  // One row is one item however many tools it targets, and its tools are
  // handed over together: one at a time, each tool's copy landed on top of
  // the last and the declaration kept only the first.
  const confirm = () => {
    if (!pending) return;
    const { group, exit } = pending;
    if (exit === "keep") void onKeep(group.kind, group.name, toolsOf(group));
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
          // Every place has to hold a shape adoption can take, or the
          // offer would settle the rest and leave that one blocked with
          // the item no longer its tool's. At least one has to be a place
          // adoption can be entered through, which is a different question
          // — a folder several tools share is kept through whichever of
          // them actually holds it.
          const keepableHere =
            adoptable.includes(group.kind) &&
            group.installations.every((row) => canKeep(row.cause)) &&
            group.installations.some((row) => canBeKept.has(rowKey(row)));
          const replaceable = group.installations.every((row) =>
            canReplace(row.cause),
          );
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
                <KindHarnessChips
                  kind={group.kind}
                  harnesses={toolsOf(group)}
                />
              </span>
              {/* Each exit says what it does, under the control that does
                  it — a row with no Keep button then carries only the line
                  telling the reader how to keep the files themselves. Two
                  slots of a fixed width, kept whether or not the row fills
                  them: a column that moves from row to row is what makes a
                  list of these hard to read. */}
              <div className="grid shrink-0 grid-cols-[15rem_15rem] gap-4">
                {keepableHere ? (
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
                  <span className="text-[13px] text-muted-foreground">
                    {MOVE_FILES_YOURSELF}
                  </span>
                )}
                {replaceable ? (
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
                ) : (
                  // The slot stays, empty: collapsing it would pull the
                  // keep column across on every row that has no replace.
                  <span />
                )}
              </div>
            </div>
          );
        })}
      </div>
      <BlockedDeclarationConfirm
        pending={pending}
        where={where}
        toolsOf={toolsOf}
        alsoApplies={alsoApplies}
        busy={busy}
        onConfirm={confirm}
        onDismiss={() => setPending(null)}
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
    <span className="flex flex-col items-start gap-1">
      {control}
      <span className="text-[13px] text-muted-foreground">{consequence}</span>
    </span>
  );
}
