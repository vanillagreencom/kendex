import { cn } from "@/lib/utils";

// The disc is a wash of the tone, not a solid: at full strength a red
// circle the size of a paragraph reads as an alarm, and the number is
// advisory. The digits carry the same tone at full strength, so the figure
// stays legible against the wash in either theme.
const TONE_CLASSES = {
  good: "bg-good/15 text-good",
  warning: "bg-warning/15 text-warning",
  critical: "bg-critical/15 text-critical",
  muted: "bg-muted-foreground/15 text-muted-foreground",
} as const;

const SIZE_CLASSES = {
  sm: "size-7 text-[11px]",
  md: "size-14 text-lg",
} as const;

/**
 * A safety score as one figure: the number inside a semi-transparent disc
 * toned by the worst thing found.
 *
 * Decorative on purpose. The colour and the number both say how a package
 * scored, and neither says what the score is a reading of — so every caller
 * puts the words beside it (`safetyHeadline`, `safetyDotWords`), and this
 * stays out of the reading order rather than making a screen reader announce
 * a bare number twice.
 */
export function ScoreCircle({
  score,
  tone,
  size = "md",
  className,
}: {
  /** Null where nothing has answered yet — the disc shows a dash rather
   *  than a zero, which is a score a package can actually earn. */
  score: number | null;
  tone: keyof typeof TONE_CLASSES;
  size?: keyof typeof SIZE_CLASSES;
  className?: string;
}) {
  return (
    <span
      aria-hidden
      className={cn(
        "inline-flex shrink-0 items-center justify-center rounded-full font-medium tabular-nums",
        SIZE_CLASSES[size],
        TONE_CLASSES[tone],
        className,
      )}
    >
      {score ?? "—"}
    </span>
  );
}
