import {
  PreviewCard,
  PreviewCardContent,
  PreviewCardTrigger,
} from "@/components/ui/preview-card";
import { MORE_ABOUT_PACKAGE_LABEL } from "@/lib/copy";
import { opensLabel } from "@/lib/opens-on-activate";
import { previewSummary } from "@/lib/package-summary";
import { cn } from "@/lib/utils";

/** A package's name, and the words its author wrote about it on hover or
 *  on focus.
 *
 *  The name is the package's link wherever it appears, so it stays a real
 *  button and opening it is one press whether or not the preview is up.
 *  The preview is a card and not a tooltip because it holds a control:
 *  where the author wrote more than the card shows, More opens the
 *  package's own page, which shows all of it — one destination, never a
 *  card that grows. The card is reachable by pointer and by keyboard, and
 *  stays open while either moves into it.
 *
 *  A package whose author wrote nothing gets no preview: an empty card
 *  that opens on every pass of the pointer is noise, and the blank state
 *  is a supported one. */
export function PackageName({
  name,
  summary,
  onOpen,
  className,
}: {
  name: string;
  /** What the author says the package does, or null where they wrote
   *  nothing reachable. */
  summary: string | null;
  onOpen: () => void;
  className?: string;
}) {
  const label = opensLabel(name);
  const button = (
    <button
      type="button"
      onClick={onOpen}
      aria-label={label}
      className={cn(
        "block min-w-0 truncate text-left hover:underline",
        className,
      )}
    >
      {name}
    </button>
  );
  if (!summary) return button;
  const { shown, truncated } = previewSummary(summary);
  return (
    <PreviewCard>
      <PreviewCardTrigger render={button} />
      <PreviewCardContent className="max-w-96">
        <p className="text-[13px] font-medium">{name}</p>
        <p className="mt-1 text-[13px] text-muted-foreground">{shown}</p>
        {truncated ? (
          <button
            type="button"
            onClick={onOpen}
            className="mt-2 text-[13px] font-medium underline underline-offset-2"
          >
            {MORE_ABOUT_PACKAGE_LABEL}
          </button>
        ) : null}
      </PreviewCardContent>
    </PreviewCard>
  );
}
