import type { ItemKind, Scope } from "@/bindings";
import { ScoreCircle } from "@/components/score-circle";
import { ScoreTooltip } from "@/components/score-tooltip";
import {
  installedScoreWords,
  SAFETY_CHECK_FAILED,
  SAFETY_DOT_UNCHECKED,
  severityTone,
} from "@/lib/copy-safety";
import { type SafetyStanding, safetyStanding } from "@/lib/installed-safety";
import { useAuditStore } from "@/stores/audit";

/** What the audit says about one installed package right now, ready to
 *  draw: the standing — see [SafetyStanding] — plus what only a store can
 *  answer. The standing is one value on purpose: the words a score shows
 *  and the place they are true of are decided together, so no surface can
 *  pair them wrongly. */
export interface InstalledReading {
  standing: SafetyStanding;
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
  // Worked out on every render rather than inside a selector: the standing
  // is a fresh object each call, and a selector returning one of those
  // would re-render the page against itself forever.
  const standing = safetyStanding(
    views,
    auditFailure,
    auditedAt !== null,
    kind,
    name,
    scopes,
  );
  return {
    standing,
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
  const { standing } = reading;
  // Read off the one standing, so the words and the place `onOpen` lands on
  // are the same answer.
  const scored =
    standing.state === "read" || standing.state === "stale"
      ? standing.result
      : null;
  const words = scored
    ? installedScoreWords(
        scored.safety.score,
        scored.skipped.length,
        scored.findings,
        standing.state === "stale",
        reading.checkedAt,
      )
    : standing.state === "failed" || standing.state === "unavailable"
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
      {/* A kept reading stops being drawn as a current severity: the
          number stays, the hue goes. */}
      <ScoreCircle
        size="sm"
        score={scored?.safety.score ?? null}
        tone={
          standing.state === "read"
            ? severityTone(scored?.findings ?? [])
            : "muted"
        }
      />
    </ScoreTooltip>
  );
}
