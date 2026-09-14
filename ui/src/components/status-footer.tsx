import { RefreshCw } from "lucide-react";
import { footerMarker } from "@/components/home/attention-rows";
import { useAttentionRows } from "@/components/home/use-attention-rows";
import { StatusDot } from "@/components/status-dot";
import { STATUS_TONES } from "@/components/status-note";
import {
  SCANNING_LABEL,
  scanFailedStatusLabel,
  scanStatusLabel,
} from "@/lib/copy";
import { attentionFooterLabel } from "@/lib/error-copy";
import { exactTime, relativeTime } from "@/lib/relative-time";
import { useNowTick } from "@/lib/use-now-tick";
import { cn } from "@/lib/utils";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";

// A persistent strip across the whole window, not just the content pane —
// scan freshness and problems apply regardless of which page you're looking
// at.
export function StatusFooter() {
  const scanning = useScanStore((s) => s.scanning);
  const lastScanAt = useScanStore((s) => s.lastScanAt);
  const scanError = useScanStore((s) => s.error);
  // What the Problems page holds, one per item it draws: the only thing on
  // screen that says so from anywhere in the app.
  const marker = footerMarker(useAttentionRows());
  const goTo = useNavStore((s) => s.goTo);

  // "Scanned Nm ago" goes stale on its own; nothing else re-renders this
  // component often enough to keep it honest.
  const now = useNowTick();

  return (
    <footer className="flex h-7 shrink-0 items-center border-t bg-background px-4 text-xs text-muted-foreground">
      <span className="flex items-center gap-3">
        {marker ? (
          <button
            type="button"
            className={cn(
              "flex items-center gap-1.5 hover:opacity-80",
              STATUS_TONES[marker.tone].text,
            )}
            onClick={() => goTo("problems")}
          >
            <StatusDot tone={marker.tone} />
            {attentionFooterLabel(marker.problems, marker.decisions)}
          </button>
        ) : null}
        <span
          className="flex items-center gap-1.5"
          title={lastScanAt ? exactTime(lastScanAt) : undefined}
        >
          {scanning ? (
            <>
              <RefreshCw className="size-3 animate-spin" />
              {SCANNING_LABEL}
            </>
          ) : scanError !== null ? (
            // Never scanned is a failed status; a kept result is
            // last-known — either way, not "Up to date".
            <>
              <StatusDot tone={lastScanAt ? "warning" : "critical"} />
              {scanFailedStatusLabel(
                lastScanAt ? relativeTime(lastScanAt, now) : null,
              )}
            </>
          ) : (
            scanStatusLabel(lastScanAt ? relativeTime(lastScanAt, now) : null)
          )}
        </span>
      </span>
    </footer>
  );
}
