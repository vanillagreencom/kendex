import { Button } from "@/components/ui/button";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  COULD_NOT_CHECK,
  changesToReview,
  REVIEW_CHANGES_LABEL,
} from "@/lib/copy-project-changes";
import { rescanEverything } from "@/lib/rescan";
import { useNavStore } from "@/stores/nav";
import {
  changesFor,
  pendingCount,
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
  // Whether any read has answered yet. A first read still on its way says
  // nothing at all — it will answer on its own, and a notice meanwhile would
  // flash on every start-up. Once one has settled, no row for this project
  // is not "no changes": it is a project the read did not cover, and drawing
  // nothing there is the claim `stores/project-changes.ts` refuses to make.
  const asked = useProjectChangesStore((s) => s.read.status !== "pending");
  const goToProjectChanges = useNavStore((s) => s.goToProjectChanges);
  const count = pendingCount(row);

  if (count === null) {
    if (!asked) return null;
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
  if (count === 0) return null;
  return (
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
  );
}
