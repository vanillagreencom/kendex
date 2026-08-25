import { useMemo } from "react";
import type { ItemKind } from "@/bindings";
import { ScoreCircle } from "@/components/score-circle";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  installedScoreWords,
  SAFETY_DOT_UNCHECKED,
  severityTone,
} from "@/lib/copy-safety";
import { installedSafety } from "@/lib/installed-safety";
import { useAuditStore } from "@/stores/audit";

/** What the copy on disk scored, small enough to sit beside a name in a
 *  table row.
 *
 *  The disc is decorative, so the words go in the row's own text: the
 *  trigger takes focus, which puts the score a tab away for a keyboard and
 *  reads it out for a screen reader, and the popup repeats it for a
 *  pointer. Until the audit has answered the disc shows a dash with the
 *  words saying so — a cell that simply vanished would read as a package
 *  nothing was found in. */
export function InstalledScore({
  kind,
  name,
}: {
  kind: ItemKind;
  name: string;
}) {
  // Every place this package is installed, folded into one reading: the
  // row above is about the package, not about one of its places.
  const views = useAuditStore((s) => s.views);
  const result = useMemo(
    () => installedSafety(views, kind, name),
    [views, kind, name],
  );
  const words = result
    ? installedScoreWords(
        result.safety.score,
        result.skipped.length,
        result.findings,
      )
    : SAFETY_DOT_UNCHECKED;
  return (
    <Tooltip>
      <TooltipTrigger className="inline-flex shrink-0 items-center rounded-full outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50">
        <ScoreCircle
          size="sm"
          score={result?.safety.score ?? null}
          tone={result ? severityTone(result.findings) : "muted"}
        />
        <span className="sr-only">{words}</span>
      </TooltipTrigger>
      <TooltipContent side="right" className="max-w-72">
        {words}
      </TooltipContent>
    </Tooltip>
  );
}
