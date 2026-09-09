import { cn } from "@/lib/utils";

/** Something kendex started is still running, said in words with three
 *  small blocks keeping time beside them.
 *
 *  The words are the state; the blocks only show it is still moving. No
 *  percentage is drawn, because nothing here counts steps — an invented
 *  one is a claim about how far along a read is that nobody measured. The
 *  `status` role carries a polite live region, so the sentence is read out
 *  when it appears without taking focus off whatever the reader is doing.
 *
 *  Under a reduced-motion setting the blocks hold still and the words are
 *  the whole indicator, which is why they say the state rather than
 *  labelling the animation. */
export function Activity({
  label,
  className,
}: {
  label: string;
  /** What this indicator sits in — the caller owns its type step, because
   *  the same running state is a row label on a card and a line in a
   *  dialog. */
  className?: string;
}) {
  return (
    <span
      role="status"
      className={cn(
        "flex items-center gap-2 text-[13px] text-muted-foreground",
        className,
      )}
    >
      <span aria-hidden className="flex gap-0.5">
        {BEATS.map((delay) => (
          <span
            key={delay}
            className={cn(
              "size-1.5 rounded-xs bg-current animate-pulse motion-reduce:animate-none",
              delay,
            )}
          />
        ))}
      </span>
      {label}
    </span>
  );
}

/** Three blocks a beat apart, so the row reads as one thing moving rather
 *  than three pulsing together. Written as classes rather than an inline
 *  delay so the whole indicator is one set of tokens. */
const BEATS = [
  "[animation-delay:0ms]",
  "[animation-delay:160ms]",
  "[animation-delay:320ms]",
];
