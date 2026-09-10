import { Button } from "@/components/ui/button";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  COULD_NOT_CHECK,
  changesToReview,
  LAST_CHECKED_NOTE,
  REVIEW_CHANGES_LABEL,
} from "@/lib/copy-project-changes";
import { rescanEverything } from "@/lib/rescan";
import { useNavStore } from "@/stores/nav";
import {
  changesFor,
  pendingCount,
  surenessOf,
  useProjectChangesStore,
} from "@/stores/project-changes";

/** One project's pending kendex changes, as a quiet line with a way in.
 *
 *  The same line on the Projects page's card and on the project's own view,
 *  from the same read, so the two can never disagree about what is waiting.
 *  It says the number and what the click opens: a count nobody can act on is
 *  a nag, and the review behind it is where the details belong.
 *
 *  Nothing is drawn where nothing is pending. Zero changes is not news, and
 *  a line on every project saying so would be a permanent notice about the
 *  ordinary state.
 *
 *  A read that failed is drawn, because it is not zero: it says kendex could
 *  not check, and offers the read again. */
export function ChangesLine({ root }: { root: string }) {
  const row = useProjectChangesStore((s) => changesFor(s.rows, root));
  // How sure this line may be. The four states are the store's, and telling
  // any two of them apart is the whole reason it has them: a project kendex
  // could not check must never draw the way a clean one does, and a row a
  // failed read could not confirm must not draw as a fact.
  const sureness = useProjectChangesStore((s) => surenessOf(s, root));
  const goToProjectChanges = useNavStore((s) => s.goToProjectChanges);
  const count = pendingCount(row);

  if (sureness === "waiting") return null;
  if (sureness === "unknown" || count === null) {
    return (
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-[13px] text-muted-foreground">
          {COULD_NOT_CHECK}
        </span>
        <Button
          size="sm"
          variant="outline"
          onClick={(event) => {
            event.stopPropagation();
            void rescanEverything({ announce: true });
          }}
        >
          {TRY_AGAIN_LABEL}
        </Button>
      </div>
    );
  }
  if (count === 0 && sureness === "known") return null;
  return (
    <span className="inline-flex flex-wrap items-baseline gap-2">
      <button
        type="button"
        // The card this can sit on opens the place on a click of its own, so
        // the line's own click is stopped from reaching it: a person aiming
        // at the review is not asking for the Library.
        onClick={(event) => {
          event.stopPropagation();
          goToProjectChanges(root);
        }}
        className="text-[13px] text-muted-foreground underline underline-offset-2 hover:text-foreground"
      >
        {changesToReview(count)} — {REVIEW_CHANGES_LABEL}
      </button>
      {/* The read that would have confirmed this failed, so the number is
          the last kendex could check rather than what is there now. Said
          beside it rather than instead of it: the rows are still the best
          answer available, and hiding them would lose that. */}
      {sureness === "stale" ? (
        <span className="text-[13px] text-muted-foreground">
          {LAST_CHECKED_NOTE}
        </span>
      ) : null}
    </span>
  );
}
