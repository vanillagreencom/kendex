import type { ComponentProps, ReactNode } from "react";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";

/**
 * A safety mark and the words it stands for, reachable three ways.
 *
 * The mark itself is decorative — a colour and at most a number, neither of
 * which says what it is a reading of. So the words sit in the trigger's own
 * text for a screen reader, the trigger takes focus so a keyboard reaches
 * them, and the popup repeats them for a pointer. A row can install a
 * package without its page ever opening, which is why this has to work from
 * the row.
 *
 * One shell for every table that shows a score. Two copies of it drift: the
 * focus ring is a hand-written class, and the version that stops matching is
 * the one nobody looks at.
 */
export function ScoreTooltip({
  words,
  side,
  className,
  children,
  ...trigger
}: {
  words: string;
  side?: ComponentProps<typeof TooltipContent>["side"];
  children: ReactNode;
} & Omit<ComponentProps<typeof TooltipTrigger>, "children">) {
  return (
    <Tooltip>
      <TooltipTrigger
        className={cn(
          "inline-flex shrink-0 items-center rounded-full outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50",
          className,
        )}
        {...trigger}
      >
        {children}
        <span className="sr-only">{words}</span>
      </TooltipTrigger>
      <TooltipContent side={side} className="max-w-72">
        {words}
      </TooltipContent>
    </Tooltip>
  );
}
