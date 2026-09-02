import { exactTime, relativeTime } from "@/lib/relative-time";
import { useNowTick } from "@/lib/use-now-tick";

/** A moment, read coarsely, with the exact one on the element.
 *
 *  The pairing is a component rather than a convention because a
 *  convention did not hold: the coarse reading is a string and the title
 *  was a separate hand-added attribute, so twice now a new call site got
 *  the reading and lost the date, silently. A year reading with no title
 *  says "2y ago" and nothing else — the year itself is gone.
 *
 *  The reading keeps up with the clock rather than with whatever else
 *  happens to re-render the page: it reads `lib/use-now-tick.ts`, which is
 *  the app's one rate for every age on screen and one timer for all of
 *  them however many rows a table draws.
 *
 *  A surface that composes the reading into a sentence cannot use this;
 *  see `lib/relative-time.ts` for what those do instead. */
export function Ago({
  at,
  exact,
  className,
}: {
  /** Unix milliseconds. */
  at: number;
  /** The moment as its source spelled it — a commit's own ISO-8601 string,
   *  say, which carries the committer's offset. Falls back to the
   *  timestamp rendered as UTC, which is all a filesystem mtime has. */
  exact?: string | null;
  className?: string;
}) {
  const now = useNowTick();
  return (
    <span className={className} title={exact ?? exactTime(at)}>
      {relativeTime(at, now)}
    </span>
  );
}
