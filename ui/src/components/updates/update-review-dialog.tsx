import { ChevronDown, ChevronRight } from "lucide-react";
import { useEffect, useId, useState } from "react";
import {
  commands,
  type PackageDiff,
  type Scope,
  type UpdateRow,
} from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { DiffView } from "@/components/diff/diff-view";
import {
  UPDATE_DIFF_NO_VERSIONS,
  UPDATE_DIFF_READING,
  UPDATE_REVIEW_BODY,
  UPDATE_REVIEW_CONFIRM,
  UPDATE_REVIEW_NOTHING_LEFT,
  updateDiffFailed,
  updateReviewManyTitle,
  updateReviewOneTitle,
  updateReviewSkipped,
  updateTargetLabel,
} from "@/lib/copy-updates";
import { packageDisplayName } from "@/lib/labels";
import { settled } from "@/lib/settled";
import {
  packageCount,
  placeKey,
  placeName,
  skippedPlaces,
  updatablePlaces,
} from "@/lib/update-groups";
import { versionLabel } from "@/lib/versions";

/** What a diff read came back with. A read still out and a read that failed
 *  are told apart because they are not the same thing to a person deciding
 *  whether to write: one is worth waiting for, the other is the reason the
 *  comparison is not on screen. */
type DiffRead =
  | { at: "reading" }
  | { at: "landed"; diff: PackageDiff }
  | { at: "failed"; reason: string };

/**
 * The one update flow: what the update would change, then the update.
 *
 * Every Update in the Updates table opens this — one package in one place,
 * one package everywhere, one place's worth, or everything with news — so
 * the same review stands in front of every write and a reader never has to
 * hold two ideas of what "Update" does.
 *
 * The rows handed in are whatever the caller's action covers, updatable or
 * not: this narrows them to the places an update can be taken in and counts
 * the rest. Narrowing in the caller would leave a dialog that cannot say
 * what it left out. What becomes of the changed files afterwards is not
 * asked here — the commit offer behind the write owns that question.
 */
export function UpdateReviewDialog({
  rows,
  place,
  open,
  onOpenChange,
  busy,
  onConfirm,
}: {
  /** Every row the action covers, updatable or not. */
  rows: UpdateRow[];
  /** What the place is called where the action names one — a place's own
   *  card, or a place picked off the page's menu. Null where the rows span
   *  places. */
  place: string | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  busy: boolean;
  /** Takes the places this dialog actually offered, never the rows handed
   *  in: the skipped ones were never part of the offer. */
  onConfirm: (rows: UpdateRow[]) => void;
}) {
  const targets = updatablePlaces(rows);
  const skipped = packageCount(skippedPlaces(rows));
  const packages = packageCount(targets);
  const scopes = rows.map((row) => row.scope);
  const only = targets.length === 1 ? targets[0] : null;
  const title =
    only !== undefined && only !== null
      ? updateReviewOneTitle(
          packageDisplayName(only),
          placeName(only.scope, scopes),
        )
      : updateReviewManyTitle(packages, place);

  return (
    <ConfirmDialog
      open={open}
      onOpenChange={onOpenChange}
      wide
      title={title}
      description={UPDATE_REVIEW_BODY}
      confirmLabel={UPDATE_REVIEW_CONFIRM}
      busy={busy}
      // The rows are read again behind every write, so a dialog left open
      // can outlive the news it was opened on.
      confirmDisabled={targets.length === 0}
      confirmDisabledNote={UPDATE_REVIEW_NOTHING_LEFT}
      onConfirm={() => onConfirm(targets)}
    >
      <div className="max-h-[55vh] space-y-2 overflow-y-auto">
        {targets.map((row) => (
          <UpdateTarget
            key={placeKey(row)}
            row={row}
            among={scopes}
            // One package's changes are what the reader came for; several
            // are a list to pick from first.
            defaultOpen={targets.length === 1}
          />
        ))}
      </div>
      {skipped > 0 ? (
        <p className="text-[13px] text-muted-foreground">
          {updateReviewSkipped(skipped)}
        </p>
      ) : null}
    </ConfirmDialog>
  );
}

/** One package in one place: its name, where it is, and the changes between
 *  what is installed and what the source has now. */
function UpdateTarget({
  row,
  among,
  defaultOpen,
}: {
  row: UpdateRow;
  /** The other places on this dialog, so two same-named folders read apart. */
  among: Scope[];
  defaultOpen: boolean;
}) {
  const [expanded, setExpanded] = useState(defaultOpen);
  const [read, setRead] = useState<DiffRead | null>(null);
  const bodyId = useId();
  const from = row.current;
  const to = row.latest;
  // A comparison walks two source trees, so it is read when a reader has
  // actually asked to see it.
  const wanted = expanded && from !== null && to !== null;
  const fromCommit = from?.commit ?? null;
  const toCommit = to?.commit ?? null;
  const { scope, kind, name } = row;

  useEffect(() => {
    if (!wanted || fromCommit === null || toCommit === null) return;
    let cancelled = false;
    setRead({ at: "reading" });
    void settled(
      commands.packageDiff(
        scope,
        kind,
        name,
        { at: "commit", commit: fromCommit },
        { at: "commit", commit: toCommit },
        // Both sides are commits of the source, which no rendering takes
        // part in — only an installed side reads one tool's own copy.
        null,
      ),
    ).then((response) => {
      if (cancelled) return;
      setRead(
        response.status === "ok"
          ? { at: "landed", diff: response.data }
          : { at: "failed", reason: response.error },
      );
    });
    return () => {
      cancelled = true;
    };
  }, [wanted, fromCommit, toCommit, scope, kind, name]);

  const Chevron = expanded ? ChevronDown : ChevronRight;
  return (
    <div className="overflow-hidden rounded-lg border">
      <button
        type="button"
        className="flex w-full items-center gap-2 px-3 py-2 text-left hover:bg-accent/50"
        aria-expanded={expanded}
        aria-controls={bodyId}
        onClick={() => setExpanded((value) => !value)}
      >
        <Chevron className="size-3.5 shrink-0 text-muted-foreground" />
        <span className="min-w-0 truncate text-sm font-medium">
          {updateTargetLabel(
            packageDisplayName(row),
            placeName(row.scope, among),
          )}
        </span>
      </button>
      {expanded ? (
        <div id={bodyId} className="border-t px-3 py-3">
          <TargetChanges
            fromLabel={from ? versionLabel(from) : null}
            toLabel={to ? versionLabel(to) : null}
            read={read}
          />
        </div>
      ) : null}
    </div>
  );
}

/** The changes themselves, or the one line standing in for them. A failed
 *  read says so with the reason and carries no retry of its own: closing
 *  and opening the disclosure asks again, and the update is takeable
 *  either way.
 *
 *  The app's one file-view pattern is drawn here and in no other part of
 *  this flow, so the whole update preview follows that pattern by changing
 *  this function. */
function TargetChanges({
  fromLabel,
  toLabel,
  read,
}: {
  /** Null where the standing does not carry that side's revision. */
  fromLabel: string | null;
  toLabel: string | null;
  read: DiffRead | null;
}) {
  if (fromLabel === null || toLabel === null)
    return (
      <p className="text-[13px] text-muted-foreground">
        {UPDATE_DIFF_NO_VERSIONS}
      </p>
    );
  if (read === null || read.at === "reading")
    return (
      <p className="text-[13px] text-muted-foreground">{UPDATE_DIFF_READING}</p>
    );
  if (read.at === "failed")
    return (
      <p className="text-[13px] text-muted-foreground">
        {updateDiffFailed(read.reason)}
      </p>
    );
  return <DiffView diff={read.diff} fromLabel={fromLabel} toLabel={toLabel} />;
}
