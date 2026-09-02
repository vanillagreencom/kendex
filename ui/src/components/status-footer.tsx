import { RefreshCw } from "lucide-react";
import { StatusDot } from "@/components/status-dot";
import { blockedCount } from "@/lib/audit-counts";
import {
  SCANNING_LABEL,
  scanFailedStatusLabel,
  scanStatusLabel,
} from "@/lib/copy-footer";
import { problemsFooterLabel } from "@/lib/error-copy";
import { exactTime, relativeTime } from "@/lib/relative-time";
import { useNowTick } from "@/lib/use-now-tick";
import { useNavStore } from "@/stores/nav";
import { useBlockedPlaces, useProblems } from "@/stores/problems";
import { useScanStore } from "@/stores/scan";

// A persistent strip across the whole window, not just the content pane —
// scan freshness and problems apply regardless of which page you're looking
// at.
export function StatusFooter() {
  const scanning = useScanStore((s) => s.scanning);
  const lastScanAt = useScanStore((s) => s.lastScanAt);
  const scanError = useScanStore((s) => s.error);
  const problems = useProblems();
  // A declared item nothing can install until the reader decides counts
  // here too: the Problems page is where both are answered, and the count
  // is the only thing on screen that says so from anywhere in the app.
  const blocked = useBlockedPlaces();
  const waiting = problems.length + blockedCount(blocked);
  const goTo = useNavStore((s) => s.goTo);

  // "Scanned Nm ago" goes stale on its own; nothing else re-renders this
  // component often enough to keep it honest.
  const now = useNowTick();

  return (
    <footer className="flex h-7 shrink-0 items-center border-t bg-background px-4 text-xs text-muted-foreground">
      <span className="flex items-center gap-3">
        {waiting > 0 ? (
          <button
            type="button"
            className="flex items-center gap-1.5 text-critical hover:text-critical/80"
            onClick={() => goTo("problems")}
          >
            <StatusDot tone="critical" />
            {problemsFooterLabel(waiting)}
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
