import { Check, Star } from "lucide-react";
import type { DirectoryRow } from "@/bindings";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  directoryCountsLabel,
  FEATURED_MARKER,
  SUBSCRIBE_MEANS,
  SUBSCRIBED_MARKER,
} from "@/lib/copy-marketplaces";

/** One listed marketplace, as a card. The card opens it — what it offers is
 * browsable before subscribing — and Subscribe stays a separate click, with
 * the sentence saying what subscribing does attached to the button rather
 * than left for the person to find out by pressing it. */
export function DirectoryCard({
  row,
  subscribed,
  onOpen,
  onSubscribe,
}: {
  row: DirectoryRow;
  /** From the live subscription list, not the directory's snapshot. */
  subscribed: boolean;
  onOpen: () => void;
  onSubscribe: () => void;
}) {
  return (
    <Card className="gap-0 overflow-hidden py-0 transition-colors hover:border-input">
      <button
        type="button"
        className="flex-1 cursor-pointer px-4 pt-4 pb-3 text-left hover:bg-accent/40"
        onClick={onOpen}
      >
        <div className="flex items-start gap-2">
          <span className="min-w-0 flex-1 truncate text-sm font-medium">
            {row.name}
          </span>
          {row.featured ? (
            <Badge variant="warning" className="gap-1">
              <Star className="size-3" /> {FEATURED_MARKER}
            </Badge>
          ) : null}
        </div>
        <p className="mt-0.5 truncate font-mono text-xs text-muted-foreground">
          {row.repo}
        </p>
        {row.description ? (
          <p className="mt-2 line-clamp-2 text-sm text-muted-foreground">
            {row.description}
          </p>
        ) : null}
      </button>
      <div className="flex items-center gap-2 border-t px-4 py-2.5">
        <span className="min-w-0 flex-1 truncate text-xs text-muted-foreground tabular-nums">
          {directoryCountsLabel(row.packageCount, row.bundleCount)}
        </span>
        {subscribed ? (
          <span className="flex shrink-0 items-center gap-1 text-xs font-medium text-good">
            <Check className="size-3.5" /> {SUBSCRIBED_MARKER}
          </span>
        ) : (
          <Tooltip>
            <TooltipTrigger
              render={
                <Button size="sm" variant="outline" onClick={onSubscribe}>
                  Subscribe
                </Button>
              }
            />
            <TooltipContent className="max-w-72">
              {SUBSCRIBE_MEANS}
            </TooltipContent>
          </Tooltip>
        )}
      </div>
    </Card>
  );
}

export function agoLabel(iso: string): string {
  const seconds = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (seconds < 90) return "just now";
  if (seconds < 5400) return `${Math.round(seconds / 60)}m ago`;
  if (seconds < 129_600) return `${Math.round(seconds / 3600)}h ago`;
  return `${Math.round(seconds / 86_400)}d ago`;
}

export function dayOf(iso: string): string {
  return iso.slice(0, 10);
}
