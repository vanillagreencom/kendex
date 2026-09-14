import {
  ArrowUpCircle,
  FolderGit2,
  Home,
  Library,
  RefreshCw,
  Settings,
  SlidersHorizontal,
  Store,
  TerminalSquare,
} from "lucide-react";
import { useEffect } from "react";
import { commands } from "@/bindings";
import { CLASS_TONES } from "@/components/home/attention-rows";
import { useAttentionRows } from "@/components/home/use-attention-rows";
import { SidebarAccount } from "@/components/sidebar-account";
import { SidebarNotice } from "@/components/sidebar-notice";
import { Button } from "@/components/ui/button";
import { UPDATES_ATTENTION_TITLE } from "@/lib/copy";
import { newUpdatesLabel, unreadablePlacesLabel } from "@/lib/copy-updates";
import { scopeNames } from "@/lib/labels";
import { SIDEBAR_ROW } from "@/lib/layout";
import { rescanEverything } from "@/lib/rescan";
import { isSearchShortcutKey } from "@/lib/search-shortcut";
import { visibleUpdateCount } from "@/lib/update-groups";
import { cn } from "@/lib/utils";
import { type Page, useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";

// A nav item is the shared sidebar row in the nav's own typeface.
const NAV_ROW = `${SIDEBAR_ROW} font-mono text-sm`;

// The fills the Updates badge wears, spelled whole so the stylesheet build
// finds each class.
const BADGE_FILLS = {
  critical: "bg-critical/15 text-critical",
  info: "bg-info/15 text-info",
} as const;

const NAV: { page: Page; label: string; icon: typeof Home }[] = [
  { page: "home", label: "Home", icon: Home },
  { page: "library", label: "My Library", icon: Library },
  { page: "marketplaces", label: "Marketplaces", icon: Store },
  { page: "updates", label: "Updates", icon: ArrowUpCircle },
  { page: "harnesses", label: "Harnesses", icon: TerminalSquare },
  { page: "projects", label: "Projects", icon: FolderGit2 },
  { page: "customize", label: "Customize", icon: SlidersHorizontal },
  { page: "settings", label: "Settings", icon: Settings },
];

export function Sidebar() {
  const { page, setPage, focusSearch } = useNavStore();
  const scanning = useScanStore((s) => s.scanning);
  const updateCount = useUpdatesStore((s) => visibleUpdateCount(s.rows));
  // A failed check keeps the last rows, so any count shown is last-known;
  // the badge wears the Problem tone for it. With no rows at all, "?" is
  // the honest number: absence would read as "nothing to update".
  const updatesUnchecked = useUpdatesStore((s) => s.read.error !== null);
  // A project whose records this build refuses leaves every other project's
  // standing intact, so the badge says which project rather than reporting
  // the whole machine unchecked.
  const unreadable = useUpdatesStore((s) => s.unreadable);
  const updatesIncomplete = updatesUnchecked || unreadable.length > 0;
  // An update notice not yet read wears the Update tone; once read, the
  // count stays in the neutral fill.
  const updatesUnread = useAttentionRows().some(
    (row) => row.class === "update",
  );
  const badgeTone = updatesIncomplete
    ? CLASS_TONES.problem
    : updatesUnread
      ? CLASS_TONES.update
      : null;
  // Unread is said in words and weight as well as fill.
  const unreadLabel =
    badgeTone === CLASS_TONES.update ? newUpdatesLabel(updateCount) : undefined;

  // The shortcut lives in the always-mounted chrome so "/" works on every
  // page, not only the one holding the search box.
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!isSearchShortcutKey(event.key, event.target as HTMLElement | null))
        return;
      event.preventDefault();
      focusSearch();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [focusSearch]);

  return (
    <aside className="flex h-full w-56 shrink-0 flex-col border-r bg-sidebar text-sidebar-foreground">
      {/* biome-ignore lint/a11y/noStaticElementInteractions: double-click here is a convenience alias for the maximize button already on screen */}
      <div
        data-tauri-drag-region
        onDoubleClick={() => void commands.windowToggleMaximize()}
        className="flex items-center justify-between px-4 pt-4 pb-3"
      >
        {/* Weight carries the mark rather than a second typeface: the "ken"
            is the thing to recognise, "dex" is the word it sits in. */}
        <span className="font-mono text-[15px] tracking-tight">
          <span className="font-bold">ken</span>
          <span className="font-light text-foreground/80">dex</span>
        </span>
        <Button
          variant="ghost"
          size="icon"
          aria-label="Scan again"
          title="Scan again"
          onClick={() => void rescanEverything({ announce: true })}
          disabled={scanning}
        >
          <RefreshCw className={cn("size-4", scanning && "animate-spin")} />
        </Button>
      </div>
      {/* The nav gives way rather than pushing its siblings out of a
          clipped column: `min-h-0` lets the flex child shrink below the
          height its rows want, and the scrollbar appears only once it has.
          Without it, a short window — 900x600 at 200% zoom, both of which
          this app allows — puts the foot of the sidebar past the clip with
          nothing able to scroll to it. */}
      <nav className="flex min-h-0 flex-1 flex-col gap-0.5 overflow-y-auto px-2">
        {NAV.map(({ page: target, label, icon: Icon }) => (
          <button
            key={target}
            type="button"
            onClick={() => setPage(target)}
            className={cn(
              NAV_ROW,
              "transition-colors",
              page === target
                ? "border-border/70 bg-sidebar-accent font-medium text-sidebar-foreground"
                : "text-muted-foreground hover:bg-sidebar-accent/40 hover:text-foreground",
            )}
          >
            <Icon
              className={cn(
                "size-[18px] shrink-0",
                page === target ? "" : "opacity-70",
              )}
            />
            <span className="flex-1 text-left">{label}</span>
            {target === "updates" && (updateCount > 0 || updatesIncomplete) ? (
              <span
                title={
                  updatesUnchecked
                    ? UPDATES_ATTENTION_TITLE
                    : unreadable.length > 0
                      ? unreadablePlacesLabel(
                          scopeNames(unreadable.map((place) => place.scope)),
                        )
                      : unreadLabel
                }
                className={cn(
                  "rounded px-1.5 py-0.5 text-[11px] font-medium tabular-nums",
                  badgeTone === null
                    ? "bg-foreground/[0.09]"
                    : BADGE_FILLS[badgeTone],
                  unreadLabel !== undefined && "font-semibold",
                )}
              >
                {updateCount > 0 ? updateCount : "?"}
                {unreadLabel === undefined ? null : (
                  <span className="sr-only">{unreadLabel}</span>
                )}
              </span>
            ) : null}
          </button>
        ))}
      </nav>
      <SidebarNotice />
      <SidebarAccount />
    </aside>
  );
}
