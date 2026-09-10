import { BookmarkCheck, Bookmark as BookmarkIcon } from "lucide-react";
import { useEffect } from "react";
import { toast } from "sonner";
import type { BookmarkItem, Catalog } from "@/bindings";
import { Button } from "@/components/ui/button";
import { bookmarkOf, bookmarkTarget, savedAs } from "@/lib/bookmark-target";
import {
  bookmarkLabel,
  forgotToast,
  removeBookmarkLabel,
  savedToast,
} from "@/lib/copy-bookmarks";
import { cn } from "@/lib/utils";
import { useBookmarksStore } from "@/stores/bookmarks";
import { useMarketplacesStore } from "@/stores/marketplaces";

/** Save this marketplace item, or forget it — the one control, wherever a
 *  package or a curated set is named.
 *
 *  It is a control inside whatever names the item, never the way into it:
 *  `opensOnActivate` reads a button inside a row, a card or a header as
 *  having answered the click, so ticking this leaves the reader where they
 *  were. It keeps its own focus stop for the same reason, so a keyboard
 *  reaches it without opening the row it sits in.
 *
 *  What it draws comes from the one saved list the whole app reads, so the
 *  marketplace row, the package page, the set card and the set page all
 *  say the same thing about the same item and all change together.
 *
 *  Nothing is drawn until the marketplace this item comes from can be
 *  named: a bookmark records the repository rather than a per-place alias,
 *  and a control offered before that read lands would save under a guess. */
export function BookmarkButton({
  catalog,
  item,
  name,
  reveal,
  className,
}: {
  catalog: Catalog;
  item: BookmarkItem;
  name: string;
  /** Whether this sits inside a row or card whose other controls appear on
   *  hover. Set there and nowhere else: a page header's actions are the
   *  page's own and have nothing to appear out of. A saved item stays on
   *  screen either way — that it is saved is a fact the surface states, and
   *  a fact behind hover is one nobody can scan a list for. */
  reveal?: boolean;
  className?: string;
}) {
  const rows = useMarketplacesStore((s) => s.rows);
  const summaries = useMarketplacesStore((s) => s.summaries);
  const saved = useBookmarksStore((s) => s.saved);
  const busy = useBookmarksStore((s) => s.busy);
  const ensure = useBookmarksStore((s) => s.ensure);
  const add = useBookmarksStore((s) => s.add);
  const remove = useBookmarksStore((s) => s.remove);

  // The list this control draws from, read once for the whole app: a
  // table draws one of these per row, and a read per row would resolve
  // every saved item once per package on screen.
  useEffect(() => {
    ensure();
  }, [ensure]);

  const target = bookmarkTarget(catalog, rows, summaries);
  if (target === null) return null;
  const held = savedAs(saved, target, item, name);
  const label = held ? removeBookmarkLabel(name) : bookmarkLabel(name);
  const Icon = held ? BookmarkCheck : BookmarkIcon;

  const toggle = () => {
    const bookmark = held?.bookmark ?? bookmarkOf(target, item, name);
    const saving = held ? remove(bookmark) : add(bookmark);
    void saving.then((ok) => {
      if (!ok) return;
      toast.success(held ? forgotToast(name) : savedToast(name));
    });
  };

  return (
    <Button
      type="button"
      size="icon"
      variant="ghost"
      aria-label={label}
      aria-pressed={held !== undefined}
      title={label}
      disabled={busy}
      onClick={toggle}
      className={cn(
        "size-8 cursor-pointer text-muted-foreground",
        reveal &&
          !held &&
          "opacity-0 transition-opacity group-hover:opacity-100 focus-visible:opacity-100",
        className,
      )}
    >
      <Icon className={cn("size-4", held && "text-foreground")} />
    </Button>
  );
}
