import { useState } from "react";
import type { DriftRow, HarnessId } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { KindHarnessChips } from "@/components/kind-harness-chips";
import { Button } from "@/components/ui/button";
import {
  ALSO_APPLIES,
  ask,
  IN_THE_WAY_BODY,
  KEEP_FILES_CONSEQUENCE,
  KEEP_FILES_LABEL,
  MOVE_FILES_YOURSELF,
  type Pending,
  REPLACE_FILES_CONSEQUENCE,
  REPLACE_FILES_LABEL,
} from "@/lib/copy-in-the-way";
import {
  type MergedDriftRow,
  positionsOf,
  summarizePaths,
} from "@/lib/drift-merge";
import type { Exits } from "@/lib/exits";

/**
 * Items kendex.toml asks for whose files were already on disk. Both ways
 * out live on the row a person is reading: keeping the files hands them to
 * kendex as they are, replacing them installs what was asked for and sends
 * the old copies to the trash. Neither is safe to guess, and the plan
 * cannot move until one is picked.
 *
 * Not every row has both. A folder where one file goes cannot be kept as
 * it stands, and a link somebody else set up is not this position's bytes
 * to replace — so each control is drawn from what core said the position
 * allows, never from the kind or the cause.
 */
export function BlockedDeclarations({
  rows,
  exits,
  alsoApplies,
  busy,
  onKeep,
  onReplace,
}: {
  rows: MergedDriftRow[];
  /** Which ways out each installation has, answered by core. The page
   *  never works them out for itself: a button drawn that way fails on the
   *  click the moment the two disagree. */
  exits: Exits;
  /** Whether this place has other changes waiting, which the same apply
   *  carries — every apply is the whole place's. */
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

  // Every position the row is about, which is more than one where a tree is
  // read through a harness-native link: core names the second, and a
  // summary over the first alone would show one directory and move two.
  const where = (group: MergedDriftRow) =>
    summarizePaths(group.installations.flatMap(positionsOf));
  // Every tool the move acts on, which is not the same as every tool with a
  // row on screen: a folder somebody shared by hand is read by whoever
  // links at it, and one left out is one whose shortcut is repointed
  // without warning. Core answers this per row; the page unions the answers
  // and never filters them, since the keep clears every link either way.
  const named = (group: MergedDriftRow) => [
    ...new Set(group.installations.flatMap((row) => exits.tools(row))),
  ];

  // One row is one item however many tools it targets, and its tools are
  // handed over together: one at a time, each tool's copy landed on top of
  // the last and the declaration kept only the first.
  const confirm = () => {
    if (!pending) return;
    const { group, exit } = pending;
    if (exit === "keep") void onKeep(group.kind, group.name, named(group));
    else void onReplace(group.kind, group.name);
    setPending(null);
  };

  const asked = pending && ask(pending, where(pending.group), exits);

  return (
    <div className="overflow-hidden rounded-lg border">
      <p className="border-b bg-muted/40 px-3 py-2 text-[13px] text-foreground/75">
        {IN_THE_WAY_BODY}
      </p>
      <div className="divide-y divide-border/60">
        {rows.map((group) => {
          const paths = where(group);
          // Every place has to let the item be kept, or the offer would
          // settle the rest and leave that one blocked with the item no
          // longer its tool's. At least one has to be a place keeping acts
          // through, which is a different question — a folder several tools
          // share is kept through whichever of them holds it.
          const keepable =
            group.installations.every((row) => exits.keep(row)) &&
            group.installations.some((row) => exits.enter(row));
          const replaceable = group.installations.every((row) =>
            exits.replace(row),
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
                <KindHarnessChips kind={group.kind} harnesses={named(group)} />
              </span>
              {/* Each exit says what it does, under the control that does
                  it — a row with no Keep button then carries only the line
                  telling the reader how to keep the files themselves. Two
                  slots of a fixed width, kept whether or not the row fills
                  them: a column that moves from row to row is what makes a
                  list of these hard to read. */}
              <div className="grid shrink-0 grid-cols-[15rem_15rem] gap-4">
                {keepable ? (
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
      <ConfirmDialog
        open={asked != null}
        onOpenChange={(open) => {
          if (!open) setPending(null);
        }}
        title={asked?.title ?? ""}
        description={
          asked ? `${asked.body}${alsoApplies ? ALSO_APPLIES : ""}` : undefined
        }
        confirmLabel={asked?.label ?? ""}
        destructive={asked?.destructive}
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
    <span className="flex flex-col items-start gap-1">
      {control}
      <span className="text-[13px] text-muted-foreground">{consequence}</span>
    </span>
  );
}
