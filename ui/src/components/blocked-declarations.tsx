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
  keepSharedConfirmBody,
  MOVE_FILES_YOURSELF,
  REPLACE_FILES_CONFIRM_LABEL,
  REPLACE_FILES_CONSEQUENCE,
  REPLACE_FILES_LABEL,
  replaceFilesConfirmBody,
  replaceFilesConfirmTitle,
} from "@/lib/copy-in-the-way";
import { type MergedDriftRow, summarizePaths } from "@/lib/drift-merge";
import { canKeep, canReplace } from "@/lib/drift-zones";
import { harnessName } from "@/lib/labels";

/** Which exit a row is waiting on a confirmation for. */
type Pending = { group: MergedDriftRow; exit: "keep" | "replace" };

/** A row where every tool reads one folder through a link somebody else
 *  set up. Keeping it is a bigger move than keeping a plain folder — the
 *  folder itself goes to the trash and links kendex cannot see will break
 *  — so it gets the confirmation that names the folder and every tool. */
const isShared = (group: MergedDriftRow) =>
  group.installations.some((row) => row.cause === "shared-link");

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
  const toolsOf = (group: MergedDriftRow) => [
    ...new Set(group.installations.map((row) => row.harness)),
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

  // One action keeps its own words whichever shape it takes: only what
  // happens to the files differs, and the shared folder says the more of it.
  const keepConfirm = (group: MergedDriftRow) => ({
    title: keepFilesConfirmTitle(group.name),
    label: KEEP_FILES_CONFIRM_LABEL,
    body: isShared(group)
      ? keepSharedConfirmBody(
          where(group)?.text ?? "",
          toolsOf(group).map(harnessName),
          alsoApplies,
        )
      : keepFilesConfirmBody(alsoApplies),
  });

  return (
    <div className="overflow-hidden rounded-lg border">
      <p className="border-b bg-muted/40 px-3 py-2 text-[13px] text-foreground/75">
        {IN_THE_WAY_BODY}
      </p>
      <div className="divide-y divide-border/60">
        {rows.map((group) => {
          const paths = where(group);
          // Every installation has to allow an exit for the row to offer
          // it: one tool's position in a shape kendex cannot keep makes
          // the whole click fail.
          const keepable =
            adoptable.includes(group.kind) &&
            group.installations.every((row) => canKeep(row.cause));
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
        open={pending != null}
        onOpenChange={(open) => {
          if (!open) setPending(null);
        }}
        title={
          pending?.exit === "keep"
            ? keepConfirm(pending.group).title
            : replaceFilesConfirmTitle(pending?.group.name ?? "")
        }
        description={
          pending?.exit === "keep"
            ? keepConfirm(pending.group).body
            : replaceFilesConfirmBody(
                (pending && where(pending.group)?.text) ?? "",
                (pending && where(pending.group)?.count) ?? 0,
                alsoApplies,
              )
        }
        confirmLabel={
          pending?.exit === "keep"
            ? keepConfirm(pending.group).label
            : REPLACE_FILES_CONFIRM_LABEL
        }
        destructive={
          // A shared folder goes to the trash whole and shortcuts kendex
          // cannot see break with it, which the body says — so keeping it
          // is weighted like the replacement, and like the Library weighs
          // the same move.
          pending?.exit === "replace" || (!!pending && isShared(pending.group))
        }
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
