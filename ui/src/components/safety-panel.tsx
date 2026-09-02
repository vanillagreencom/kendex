import type { AuditResult } from "@/bindings";
import { FindingLine } from "@/components/safety-findings";
import { ScoreCircle } from "@/components/score-circle";
import { Button } from "@/components/ui/button";
import {
  SAFETY_CAVEAT,
  SAFETY_CHECK_FAILED,
  SAFETY_RETRY_LABEL,
  safetyHeadline,
  severityTone,
  staleSafetyNote,
} from "@/lib/copy-safety";
import { findingKey } from "@/lib/installed-safety";
import { exactTime } from "@/lib/relative-time";
import { cn } from "@/lib/utils";

/**
 * What a package's bytes scored, and what produced the number.
 *
 * The figure first, then the worst thing found in words, then what the
 * reading is and is not — and under all of it, one line per finding with
 * the files it fired in. Nothing here asks for an answer: the score is
 * advisory, so there is no verdict to accept and no fix line to follow.
 *
 * The same block on every package surface, installed or not, because the
 * reading is the same reading — a page that scored the same content two
 * different ways would be two different claims about one thing.
 */
export function SafetyPanel({
  result,
  notes = [],
  stale = false,
  checkedAt = null,
  onRetry,
  className,
}: {
  result: AuditResult;
  /** What this particular reading did not account for — a preview names
   *  what an install would read differently. Empty for installed content,
   *  which was read where it sits. */
  notes?: string[];
  /** The check that would have replaced this reading failed. The number
   *  stays, because it is the last thing anything knows, but it stops being
   *  presented as what the files say now. */
  stale?: boolean;
  /** When this reading was taken, so the stale line can date it. */
  checkedAt?: number | null;
  onRetry?: () => void;
  className?: string;
}) {
  const { findings, skipped } = result;
  return (
    <section className={cn("flex flex-col gap-4", className)}>
      <div className="flex items-start gap-4">
        <ScoreCircle
          score={result.safety.score}
          tone={severityTone(findings)}
        />
        <div className="min-w-0 flex-1 space-y-1">
          <h3 className="text-sm font-semibold">
            {/* The number is decorative on the disc, so it is said once
                here in text — the score and what it stands for read as one
                sentence to anyone who never sees the circle. */}
            Safety check · {result.safety.score}/100
          </h3>
          <p className="text-sm">{safetyHeadline(findings, skipped.length)}</p>
          {stale ? (
            <div
              className="flex flex-wrap items-center gap-2 text-sm text-warning"
              title={checkedAt ? exactTime(checkedAt) : undefined}
            >
              {staleSafetyNote(checkedAt)}
              {onRetry ? (
                <Button size="sm" variant="outline" onClick={onRetry}>
                  {SAFETY_RETRY_LABEL}
                </Button>
              ) : null}
            </div>
          ) : null}
          <p className="max-w-prose text-xs text-foreground/70">
            {SAFETY_CAVEAT}
          </p>
          {notes.map((note) => (
            <p key={note} className="max-w-prose text-xs text-foreground/70">
              {note}
            </p>
          ))}
        </div>
      </div>
      {findings.length > 0 ? (
        <div className="space-y-3">
          {findings.map((finding) => (
            <FindingLine key={findingKey(finding)} finding={finding} />
          ))}
        </div>
      ) : null}
    </section>
  );
}

/**
 * The check ran and could not answer, with nothing kept from before it.
 *
 * A block that rendered nothing here would read as a package the check
 * found nothing in, which is the one claim it has not made. So the failure
 * stands where the score would, and it carries the way to ask again: a
 * toast is gone by the time anybody reads the page.
 */
export function SafetyUnavailable({
  message,
  onRetry,
  className,
}: {
  /** What the audit said went wrong. Shown under the headline, because a
   *  path or a permission is usually the whole answer. */
  message: string | null;
  onRetry: () => void;
  className?: string;
}) {
  return (
    <section className={cn("flex flex-col items-start gap-2", className)}>
      <p className="text-sm">{SAFETY_CHECK_FAILED}</p>
      {message ? (
        <p className="max-w-prose text-xs text-foreground/70">{message}</p>
      ) : null}
      <Button size="sm" variant="outline" onClick={onRetry}>
        {SAFETY_RETRY_LABEL}
      </Button>
    </section>
  );
}
