import {
  ArrowUpCircle,
  CircleCheck,
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
import { Button } from "@/components/ui/button";
import { auditCounts, needsReviewCount } from "@/lib/audit-counts";
import { isSearchShortcutKey } from "@/lib/search-shortcut";
import { visibleUpdateCount } from "@/lib/update-rows";
import { cn } from "@/lib/utils";
import { useAuditStore } from "@/stores/audit";
import { type Page, useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";

// One row shape for every nav item, so the icon column and the text column
// line up down the whole sidebar. The transparent border is load-bearing:
// the selected row shows one, and without it here every other row would
// shift a pixel when selection moved.
const NAV_ROW =
  "flex h-9 items-center gap-2.5 rounded-lg border border-transparent px-2 font-mono text-sm";

const NAV: { page: Page; label: string; icon: typeof Home }[] = [
  { page: "home", label: "Home", icon: Home },
  { page: "review", label: "Review & apply", icon: CircleCheck },
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
  const { scanning, refresh } = useScanStore();
  const driftCount = useAuditStore((s) =>
    needsReviewCount(auditCounts(s.views)),
  );
  const updateCount = useUpdatesStore((s) => visibleUpdateCount(s.rows));

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
          onClick={() => void refresh({ announce: true })}
          disabled={scanning}
        >
          <RefreshCw className={cn("size-4", scanning && "animate-spin")} />
        </Button>
      </div>
      <nav className="flex flex-1 flex-col gap-0.5 px-2">
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
            {target === "review" && driftCount > 0 ? (
              <span className="rounded bg-foreground/[0.09] px-1.5 py-0.5 text-[11px] font-medium tabular-nums">
                {driftCount}
              </span>
            ) : null}
            {target === "updates" && updateCount > 0 ? (
              <span className="rounded bg-foreground/[0.09] px-1.5 py-0.5 text-[11px] font-medium tabular-nums">
                {updateCount}
              </span>
            ) : null}
          </button>
        ))}
      </nav>
    </aside>
  );
}
