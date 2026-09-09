import type { ItemKind, Scope } from "@/bindings";
import { ScoreCircle } from "@/components/score-circle";
import { ScoreTooltip } from "@/components/score-tooltip";
import {
  installedScoreWords,
  SAFETY_CHECK_FAILED,
  SAFETY_DOT_UNCHECKED,
  severityTone,
} from "@/lib/copy-safety";
import { type InstalledSafety, installedSafety } from "@/lib/installed-safety";
import { sameScope } from "@/lib/scope";
import { useAuditStore } from "@/stores/audit";

/** What the audit says about one installed package right now, and how much
 *  that is worth. A reading kept from before a failed check is not the same
 *  claim as one the check just made, so the two never arrive as one field. */
export interface InstalledReading {
  /** The reading, and the place it answers for. Over several places it is
   *  the worst-scoring one's, so anything offering a way to what is behind
   *  the number sends the reader to that place. */
  result: InstalledSafety | null;
  /** Why the last audit failed, or null. A result beside this is the check
   *  before the one that failed — so the failure is only ever this
   *  reading's own place's, or the whole audit's. Another place failing
   *  says nothing about the copy this reading is of, and would make the
   *  score read as stale over a number that is current. */
  failure: string | null;
  /** The place the failure above belongs to, where it belongs to one. Null
   *  for a failure that belongs to the audit as a whole, which names no
   *  place. It travels with the reading for the same reason the result's
   *  scope does: a surface offering a way to what is behind the words has
   *  to land where those words are true. */
  failedAt: Scope | null;
  /** No audit has answered and none has failed: the reading is still on its
   *  way, which is a wait rather than an outcome. */
  waiting: boolean;
  /** When the audit behind this reading answered, or null where none has.
   *  Only the stale wording spends it: a current reading is current, and
   *  dating it would invite the reader to work out whether to believe it. */
  checkedAt: number | null;
  retry: () => void;
}

/** The reading for one package at the places a row is about.
 *
 *  The scopes are the caller's, never "everywhere": a package's row on the
 *  Updates page is about the places that row lists, and a same-named package
 *  from an unrelated catalog elsewhere on the machine is a different package.
 */
export function useInstalledReading(
  kind: ItemKind,
  name: string,
  scopes: Scope[],
): InstalledReading {
  const views = useAuditStore((s) => s.views);
  const auditFailure = useAuditStore((s) => s.read.error);
  const auditedAt = useAuditStore((s) => s.auditedAt);
  const refresh = useAuditStore((s) => s.refresh);
  // Merged out of the store's rows on every render rather than inside a
  // selector: the merge builds a fresh object each call, and a selector
  // returning one of those would re-render the page against itself forever.
  const result = installedSafety(views, kind, name, scopes);
  // A place the audit could not read has failed for this row even when the
  // audit as a whole came back: what is on screen for it is whatever it
  // last said, and nothing has confirmed it since. The view is kept whole
  // rather than reduced to its message, because the place it failed at is
  // where that failure can be read.
  const unreadable =
    views.find(
      (view) =>
        view.error && scopes.some((scope) => sameScope(view.scope, scope)),
    ) ?? null;
  // Only a failure about the copy this reading is of qualifies it. Over
  // several places the result is one place's, so another place's failed
  // read leaves this number current and says its piece on its own row;
  // reported here it would date a reading nothing has invalidated, and
  // send anyone following it to a place the number never came from.
  const failed =
    unreadable && (result === null || sameScope(unreadable.scope, result.scope))
      ? unreadable
      : null;
  const failure = auditFailure ?? failed?.error?.message ?? null;
  return {
    result,
    failure,
    failedAt: failed?.scope ?? null,
    waiting: auditedAt === null && failure === null,
    checkedAt: auditedAt,
    retry: () => void refresh({ force: true }),
  };
}

/** What the copy on disk scored, small enough to sit beside a name in a
 *  table row.
 *
 *  The disc is decorative, so the words go in the row's own text — the
 *  trigger takes focus, which puts the score a tab away for a keyboard and
 *  reads it out for a screen reader. Until the audit has answered the disc
 *  shows a dash with the words saying so; a cell that simply vanished would
 *  read as a package nothing was found in.
 *
 *  Given `onOpen` the disc is also the way to what is behind the number:
 *  the package page's Safety tab, where the findings are. Without it the
 *  score would be a severity and a count with no finding under either. */
export function InstalledScore({
  reading,
  onOpen,
}: {
  reading: InstalledReading;
  /** Open the reading this score summarizes. A score names a thing — how
   *  safe this copy is — so it opens that thing rather than growing a
   *  second findings panel of its own. */
  onOpen?: () => void;
}) {
  const { result, failure } = reading;
  const words = result
    ? installedScoreWords(
        result.safety.score,
        result.skipped.length,
        result.findings,
        failure !== null,
        reading.checkedAt,
      )
    : failure !== null
      ? SAFETY_CHECK_FAILED
      : SAFETY_DOT_UNCHECKED;
  return (
    <ScoreTooltip
      words={words}
      side="right"
      // Never disabled, with or without something to open: the trigger is
      // the only place a keyboard reaches the words, and a disabled button
      // is out of the tab order.
      onClick={onOpen}
    >
      <ScoreCircle
        size="sm"
        score={result?.safety.score ?? null}
        tone={result ? severityTone(result.findings) : "muted"}
      />
    </ScoreTooltip>
  );
}
