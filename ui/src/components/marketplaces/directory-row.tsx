import { Star } from "lucide-react";
import type { DirectoryRow } from "@/bindings";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";

/** One listed marketplace. The row opens it — what it offers is browsable
 * before subscribing — and Subscribe stays a separate click. */
export function DirectoryRowLine({
  row,
  onOpen,
  onSubscribe,
}: {
  row: DirectoryRow;
  onOpen: () => void;
  onSubscribe: () => void;
}) {
  return (
    <div className="flex items-center gap-3 px-4 py-3">
      <button
        type="button"
        className="min-w-0 flex-1 cursor-pointer text-left"
        onClick={onOpen}
      >
        <div className="flex items-center gap-2">
          <span className="truncate text-sm font-medium">{row.name}</span>
          {row.featured ? (
            <Badge variant="secondary" className="gap-1">
              <Star className="size-3" /> featured
            </Badge>
          ) : null}
        </div>
        <div className="flex items-center gap-2">
          <span className="truncate font-mono text-xs text-muted-foreground">
            {row.repo}
          </span>
          {row.description ? (
            <span className="truncate text-xs text-muted-foreground">
              {row.description}
            </span>
          ) : null}
        </div>
      </button>
      <span className="shrink-0 text-xs text-muted-foreground">
        {row.packageCount} {row.packageCount === 1 ? "pkg" : "pkgs"}
        {row.bundleCount > 0 ? ` · ${row.bundleCount} bundles` : ""}
      </span>
      {row.subscribed ? (
        <span className="shrink-0 text-xs text-muted-foreground">
          Subscribed ✓
        </span>
      ) : (
        <Button size="sm" variant="outline" onClick={onSubscribe}>
          Subscribe
        </Button>
      )}
    </div>
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
