import { ChevronLeft } from "lucide-react";
import { Button } from "@/components/ui/button";
import { BACK_LABEL } from "@/lib/copy";
import { breadcrumbLabel, packageDisplayName } from "@/lib/labels";
import {
  CONTENT_WIDTH,
  isWidePage,
  PAGE_GUTTER,
  WIDE_CONTENT_WIDTH,
} from "@/lib/layout";
import { cn } from "@/lib/utils";
import { catalogLabel } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";

// A quiet strip above the page content — only worth showing at all once a
// cross-page link has actually left a trail to come back to. Landing on a
// page straight from the sidebar has nowhere to go back to, so nothing here
// reserves space for it.
export function NavBar() {
  const page = useNavStore((s) => s.page);
  const packageRef = useNavStore((s) => s.packageRef);
  const marketplaceRef = useNavStore((s) => s.marketplaceRef);
  const bundleRef = useNavStore((s) => s.bundleRef);
  const availableRef = useNavStore((s) => s.availableRef);
  const hasHistory = useNavStore((s) => s.history.length > 0);
  const back = useNavStore((s) => s.back);

  if (!hasHistory) return null;

  return (
    // Same gutters and measure as the page below, so the back button lines
    // up with the title it belongs to instead of floating off to its left.
    <div className={cn("pt-6", PAGE_GUTTER)}>
      <div
        className={cn(
          "flex items-center gap-0.5 text-xs text-muted-foreground",
          isWidePage(page) ? WIDE_CONTENT_WIDTH : CONTENT_WIDTH,
        )}
      >
        {/* Pulled left by the button's own padding so the chevron sits on
            the same edge as the title below it. Forward lives on the mouse's
            side button, where a trail you just walked belongs — a second
            arrow here is chrome nobody presses. */}
        <Button
          variant="quiet"
          size="icon-xs"
          className="-ml-1.5"
          aria-label={BACK_LABEL}
          title={BACK_LABEL}
          onClick={back}
        >
          <ChevronLeft className="size-4" />
        </Button>
        <span className="ml-1 min-w-0 truncate">
          {breadcrumbLabel({
            page,
            packageName: packageRef
              ? packageDisplayName(packageRef)
              : availableRef
                ? packageDisplayName(availableRef)
                : null,
            marketplaceName: catalogLabel(
              marketplaceRef ?? bundleRef?.catalog ?? availableRef?.catalog,
            ),
            bundleName: bundleRef?.bundle ?? null,
          })}
        </span>
      </div>
    </div>
  );
}
