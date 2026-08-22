import { ChevronDown, ChevronRight } from "lucide-react";
import { useState } from "react";
import type { DriftRow, ItemKind } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { KindHarnessChips } from "@/components/kind-harness-chips";
import { Button } from "@/components/ui/button";
import { type SharedLink, sharedLinkOf } from "@/lib/adopt-shared";
import {
  HIDE_ITEMS_LABEL,
  START_MANAGING_LABEL,
  showAllItemsLabel,
  startManagingAllLabel,
} from "@/lib/copy";
import {
  KEEP_FILES_CONFIRM_LABEL,
  keepFilesConfirmTitle,
  keepSharedBody,
} from "@/lib/copy-in-the-way";
import type { MergedDriftRow } from "@/lib/drift-merge";
import { summarizePaths } from "@/lib/drift-merge";
import { kindLabel } from "@/lib/labels";

// A project can carry dozens of hand-made items nobody intends to triage one
// at a time. Past this many, the list folds behind a one-line summary so the
// section stays a footnote instead of swallowing the page.
const INLINE_LIMIT = 5;

function kindCounts(rows: MergedDriftRow[]): [ItemKind, number][] {
  const counts = new Map<ItemKind, number>();
  for (const row of rows) counts.set(row.kind, (counts.get(row.kind) ?? 0) + 1);
  return [...counts.entries()];
}

// A skill installed by hand for two harnesses is one thing to adopt, not
// two — so one row carries every harness mark and one button adopts every
// installation at once.
export function UnmanagedItems({
  rows,
  busy,
  title,
  foldable: canFold = true,
  onAdopt,
}: {
  rows: MergedDriftRow[];
  busy: boolean;
  /** False on the page where this list is the whole task — there, nothing
   *  is worth hiding behind a summary. */
  foldable?: boolean;
  /** The list's heading — a project's name where several projects' lists
   *  sit under one panel heading, or nothing where the panel says it all. */
  title: string | null;
  /** Every tool an item sits at, handed over in one call. Answers whether
   *  it worked, so a list stops at the first item that did not. */
  onAdopt: (
    kind: DriftRow["kind"],
    name: string,
    harnesses: DriftRow["harness"][],
  ) => Promise<boolean>;
}) {
  const [expanded, setExpanded] = useState(false);
  const [confirmingShared, setConfirmingShared] = useState<SharedLink | null>(
    null,
  );
  if (rows.length === 0) return null;
  const foldable = canFold && rows.length > INLINE_LIMIT;
  const showList = !foldable || expanded;

  // One item at a time: every apply takes the scope's writer lock, so
  // firing them together turns all but the first into "scope is busy". The
  // first failure stops the rest — after one has failed, the others are
  // answering against a page that is now wrong, and the run would still
  // finish looking like it worked. An item's tools go in one call: taken
  // one at a time, each tool's copy landed in the local source on top of
  // the last and the declaration kept only the first.
  const adoptAll = async (groups: MergedDriftRow[]) => {
    let shared: SharedLink | null = null;
    for (const group of groups) {
      const link = sharedLinkOf(group);
      if (link) {
        // A shared folder needs its own confirmation; the first one found
        // opens it after the plain adoptions finish.
        shared ??= link;
        continue;
      }
      const harnesses = [
        ...new Set(group.installations.map((row) => row.harness)),
      ];
      if (!(await onAdopt(group.kind, group.name, harnesses))) return;
    }
    if (shared) setConfirmingShared(shared);
  };

  return (
    <div className="flex flex-col">
      {/* Which scope these are in rides inside the box as its first row, not
          as a line above it: a heading that appears only when more than one
          scope has items moves the whole block down the page as the filter
          changes. */}
      <div className="divide-y divide-border/60 rounded-lg border bg-muted/30">
        {title ? (
          <p className="px-3 py-2 text-xs font-medium text-muted-foreground">
            {title}
          </p>
        ) : null}
        {/* The summary line carries the one action that covers the whole
            list, so it stays even where nothing is folded. */}
        {foldable || rows.length > 1 ? (
          <div className="flex flex-wrap items-center gap-2 px-3 py-2.5">
            <button
              type="button"
              disabled={!foldable}
              onClick={() => setExpanded((e) => !e)}
              className="flex min-w-0 flex-1 items-center gap-1.5 text-left disabled:cursor-default"
            >
              {foldable ? (
                expanded ? (
                  <ChevronDown className="size-4 shrink-0 text-muted-foreground" />
                ) : (
                  <ChevronRight className="size-4 shrink-0 text-muted-foreground" />
                )
              ) : null}
              <span className="truncate text-sm">
                {kindCounts(rows)
                  .map(([kind, count]) => `${count} ${kindLabel(kind, count)}`)
                  .join(" · ")}
              </span>
              {foldable ? (
                <span className="shrink-0 text-xs text-muted-foreground">
                  {expanded ? HIDE_ITEMS_LABEL : showAllItemsLabel(rows.length)}
                </span>
              ) : null}
            </button>
            <Button
              size="sm"
              variant="outline"
              className="shrink-0"
              disabled={busy}
              onClick={() => void adoptAll(rows)}
            >
              {startManagingAllLabel(rows.length)}
            </Button>
          </div>
        ) : null}
        {showList
          ? rows.map((group) => {
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
                    onClick={() => void adoptAll([group])}
                  >
                    {START_MANAGING_LABEL}
                  </Button>
                </div>
              );
            })
          : null}
      </div>
      <ConfirmDialog
        open={confirmingShared != null}
        onOpenChange={(open) => {
          if (!open) setConfirmingShared(null);
        }}
        title={keepFilesConfirmTitle(confirmingShared?.group.name ?? "")}
        description={
          confirmingShared
            ? keepSharedBody(confirmingShared.target, confirmingShared.tools)
            : undefined
        }
        confirmLabel={KEEP_FILES_CONFIRM_LABEL}
        destructive
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
