import type { AuditResult, ItemKind, Scope } from "@/bindings";
import { ScoreCircle } from "@/components/score-circle";
import { ScoreTooltip } from "@/components/score-tooltip";
import {
  installedScoreWords,
  SAFETY_CHECK_FAILED,
  SAFETY_DOT_UNCHECKED,
  severityTone,
} from "@/lib/copy-safety";
import { installedSafety } from "@/lib/installed-safety";
import { sameScope } from "@/lib/scope";
import { useAuditStore } from "@/stores/audit";

/** What the audit says about one installed package right now, and how much
 *  that is worth. A reading kept from before a failed check is not the same
 *  claim as one the check just made, so the two never arrive as one field. */
export interface InstalledReading {
  result: AuditResult | null;
  /** Why the last audit failed, or null. A result beside this is the check
   *  before the one that failed. */
  failure: string | null;
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
  // last said, and nothing has confirmed it since.
  const unreadable =
    views.find(
      (view) =>
        view.error && scopes.some((scope) => sameScope(view.scope, scope)),
    )?.error ?? null;
  const failure = auditFailure ?? unreadable?.message ?? null;
  return {
    result,
    failure,
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
 *  Given `onToggle` the disc is also the way to what is behind the number.
 *  Without it the score would be the whole reading a row ever offers, which
 *  is a severity and a count with no finding under either. */
export function InstalledScore({
  reading,
  expanded = false,
  controls,
  onToggle,
}: {
  reading: InstalledReading;
  expanded?: boolean;
  /** The id of the row this opens. Named only while it is open: a control
   *  pointing at an element that is not in the document is a broken
   *  reference to anything reading the page. */
  controls?: string;
  onToggle?: () => void;
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
      aria-expanded={onToggle ? expanded : undefined}
      aria-controls={onToggle && expanded ? controls : undefined}
      onClick={onToggle}
    >
      <ScoreCircle
        size="sm"
        score={result?.safety.score ?? null}
        tone={result ? severityTone(result.findings) : "muted"}
      />
    </ScoreTooltip>
  );
}
