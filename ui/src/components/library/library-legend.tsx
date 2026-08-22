import { StatusDot } from "@/components/status-dot";
import { AS_INSTALLED_LEGEND, CUSTOMIZED_LEGEND } from "@/lib/copy-customize";

/** What the colour of a row's icon means. Rendered only when the table
 *  holds something customized — a key to a colour nobody can see is noise. */
export function LibraryLegend() {
  return (
    <div className="flex items-center gap-4 pb-2 text-xs text-muted-foreground">
      <span className="flex items-center gap-1.5">
        <StatusDot tone="muted" />
        {AS_INSTALLED_LEGEND}
      </span>
      <span className="flex items-center gap-1.5">
        <StatusDot tone="customized" />
        {CUSTOMIZED_LEGEND}
      </span>
    </div>
  );
}
