import { useState } from "react";
import type { DriftRow, ItemKind } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { KindHarnessChips } from "@/components/kind-harness-chips";
import { Button } from "@/components/ui/button";
import { adoptAll, type SharedLink, sharedLinkOf } from "@/lib/adopt-all";
import { START_MANAGING_LABEL, startManagingAllLabel } from "@/lib/copy";
import {
  manageConfirmTitle,
  manageSharedBody,
  PROCEED_LABEL,
} from "@/lib/copy-in-the-way";
import type { MergedDriftRow } from "@/lib/drift-merge";
import { summarizePaths } from "@/lib/drift-merge";
import { kindLabel } from "@/lib/labels";

function kindCounts(rows: MergedDriftRow[]): [ItemKind, number][] {
  const counts = new Map<ItemKind, number>();
  for (const row of rows) counts.set(row.kind, (counts.get(row.kind) ?? 0) + 1);
  return [...counts.entries()];
}

/**
 * One place's unmanaged items, with the offer to take them on.
 *
 * A skill installed by hand for two harnesses is one thing to adopt, not
 * two — so one row carries every harness mark and one button adopts every
 * installation at once. Nothing folds: this list is the whole task on the
 * page that shows it.
 */
export function UnmanagedItems({
  rows,
  busy,
  onAdopt,
}: {
  rows: MergedDriftRow[];
  busy: boolean;
  /** Every tool an item sits at, handed over in one call. Answers whether
   *  it worked, so a list stops at the first item that did not. */
  onAdopt: (
    kind: DriftRow["kind"],
    name: string,
    harnesses: DriftRow["harness"][],
    quiet?: boolean,
  ) => Promise<boolean>;
}) {
  const [confirmingShared, setConfirmingShared] = useState<SharedLink | null>(
    null,
  );
  if (rows.length === 0) return null;

  const startAll = async (groups: MergedDriftRow[]) => {
    const shared = await adoptAll(groups, sharedLinkOf, onAdopt);
    if (shared) setConfirmingShared(shared);
  };

  return (
    <div className="flex flex-col">
      <div className="divide-y divide-border/60 rounded-lg border bg-muted/30">
        {/* A summary row for a single item would say what the row under it
            already says, and its button would do what that row's button
            does. It earns its place once there are several to cover. */}
        {rows.length > 1 ? (
          <div className="flex flex-wrap items-center gap-2 px-3 py-2.5">
            <span className="min-w-0 flex-1 truncate text-sm">
              {kindCounts(rows)
                .map(([kind, count]) => `${count} ${kindLabel(kind, count)}`)
                .join(" · ")}
            </span>
            <Button
              size="sm"
              variant="outline"
              className="shrink-0"
              disabled={busy}
              onClick={() => void startAll(rows)}
            >
              {startManagingAllLabel(rows.length)}
            </Button>
          </div>
        ) : null}
        {rows.map((group) => {
          const paths = summarizePaths(
            group.installations.map((row) => row.detail),
          );
          const harnesses = [
            ...new Set(group.installations.map((row) => row.harness)),
          ];
          return (
            <div
              key={`${group.kind}:${group.name}:${group.state}`}
              className="flex items-center gap-3 px-3 py-3"
            >
              {/* Name over path on the left, chips in a lane of their
                      own: chips trailing the name start at a different x on
                      every row, and a column that never lines up is the
                      thing that makes a list of these hard to read. */}
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
              <Button
                size="sm"
                variant="outline"
                className="shrink-0"
                disabled={busy}
                onClick={() => void startAll([group])}
              >
                {START_MANAGING_LABEL}
              </Button>
            </div>
          );
        })}
      </div>
      <ConfirmDialog
        open={confirmingShared != null}
        onOpenChange={(open) => {
          if (!open) setConfirmingShared(null);
        }}
        title={manageConfirmTitle(confirmingShared?.group.name ?? "")}
        description={
          confirmingShared
            ? manageSharedBody(confirmingShared.target, confirmingShared.tools)
            : undefined
        }
        confirmLabel={PROCEED_LABEL}
        busy={busy}
        onConfirm={() => {
          if (confirmingShared) {
            void onAdopt(
              confirmingShared.group.kind,
              confirmingShared.group.name,
              [confirmingShared.harness],
            );
          }
          setConfirmingShared(null);
        }}
      />
    </div>
  );
}
