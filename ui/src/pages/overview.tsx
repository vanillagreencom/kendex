import { useEffect } from "react";
import { attentionRows } from "@/components/home/attention-rows";
import { AttentionSection } from "@/components/home/attention-section";
import {
  AttentionSkeleton,
  RecentSkeleton,
  StatsSkeleton,
} from "@/components/home/home-skeletons";
import { RecentActivity } from "@/components/home/recent-activity";
import { PageHeader } from "@/components/page-header";
import { Section } from "@/components/section";
import { StatTile } from "@/components/stat-tile";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import {
  MARKETPLACES_UNCHECKED_DETAIL,
  SCAN_AGAIN_LABEL,
  SCAN_FAILED_TITLE,
  SCAN_STALE_TITLE,
} from "@/lib/copy";
import { groupItems, recentItems } from "@/lib/derive";
import { harnessName } from "@/lib/labels";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useAuditStore } from "@/stores/audit";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { useUpdatesStore } from "@/stores/updates";

const RECENT_ACTIVITY_LIMIT = 6;

export function OverviewPage() {
  const { result, error, scanning, refresh } = useScanStore();
  const views = useAuditStore((s) => s.views);
  // The safety pass is the slowest thing the app does; until it has run
  // once, Home cannot say whether anything needs attention — so it says
  // that it is still looking rather than showing an empty page.
  const stillChecking = useAuditStore((s) => s.auditedAt === null);
  const projectCount = useSettingsStore(
    (s) => s.settings?.projects?.length ?? 0,
  );
  const setPage = useNavStore((s) => s.setPage);
  const goToPackage = useNavStore((s) => s.goToPackage);
  const updateRows = useUpdatesStore((s) => s.rows);
  // Rows kept from before a failed re-check are last-known, still worth a
  // line; the failure itself gets its own row below, so their absence
  // never has to stand in for "couldn't check".
  const editedPackages = updateRows.filter((row) => row.blockedByLocalEdit);
  const updatesError = useUpdatesStore((s) => s.error);
  const goTo = useNavStore((s) => s.goTo);
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const goToMarketplaces = useNavStore((s) => s.goToMarketplaces);
  const marketplaceCount = useMarketplacesStore((s) => s.rows.length);
  // `rows` survives a failed re-read; `rowsCurrent` is whether they are
  // the answer of the last one. Only a current read may put a number —
  // above all a zero — on the tile.
  const marketplacesCurrent = useMarketplacesStore((s) => s.rowsCurrent);
  const marketplacesError = useMarketplacesStore((s) => s.error);
  const loadMarketplaces = useMarketplacesStore((s) => s.load);
  useEffect(() => {
    void loadMarketplaces();
  }, [loadMarketplaces]);

  const scanAgain = (
    <Button
      size="sm"
      variant="outline"
      disabled={scanning}
      onClick={() => void refresh({ announce: true })}
    >
      {SCAN_AGAIN_LABEL}
    </Button>
  );

  // A first scan that failed is an answer, not a wait. Skeletons here would
  // say "still checking" for the rest of the session; the page says what
  // happened instead, with the retry beside it.
  if (!result && error) {
    return (
      <div>
        <PageHeader title="Home" />
        <div className={PAGE_BODY}>
          <div className={cn(CONTENT_WIDTH)}>
            <StatusNote
              tone="critical"
              title={SCAN_FAILED_TITLE}
              action={scanAgain}
            >
              {error}
            </StatusNote>
          </div>
        </div>
      </div>
    );
  }

  const rows = attentionRows({
    editedPackages,
    views,
    result,
    updatesError,
    onReview: () => setPage("review"),
    onUnmanaged: () => goTo("unmanaged"),
    onProjects: () => goTo("projects"),
    onUpdates: () => setPage("updates"),
    onLibrary: () => goToLibrary(),
    onPackage: (row) =>
      goToPackage({ kind: row.kind, name: row.name, scope: row.scope }),
  });

  const harnessNames = (result?.harnesses ?? [])
    .map((h) => harnessName(h.harness))
    .join(", ");
  const recent = result
    ? recentItems(groupItems(result.items), RECENT_ACTIVITY_LIMIT)
    : [];

  return (
    <div>
      <PageHeader title="Home" />
      <div className={PAGE_BODY}>
        <div className={cn("flex flex-col gap-10", CONTENT_WIDTH)}>
          {/* The store keeps the last good result so the page does not
              blank, but a re-scan that failed means everything below
              answers for an earlier moment — said here once, over all of
              it, rather than presented as current. */}
          {result && error ? (
            <StatusNote
              tone="warning"
              title={SCAN_STALE_TITLE}
              action={scanAgain}
            >
              {error}
            </StatusNote>
          ) : null}
          {/* Nothing to decide means nothing to say: the section is gone
              rather than standing there reporting its own emptiness. */}
          {!result || stillChecking ? (
            <Section title="Needs attention">
              <AttentionSkeleton />
            </Section>
          ) : rows.length > 0 ? (
            <Section title="Needs attention">
              <AttentionSection rows={rows} />
            </Section>
          ) : null}

          <Section title="Recently changed">
            {result ? <RecentActivity groups={recent} /> : <RecentSkeleton />}
          </Section>

          <Section title="At a glance">
            {result ? (
              <div className="grid grid-cols-4 gap-3">
                <StatTile
                  label="Harnesses"
                  value={result.harnesses.length}
                  detail={harnessNames || undefined}
                  onClick={() => goTo("harnesses")}
                />
                <StatTile
                  label="Installed"
                  value={result.items.length}
                  onClick={() => goToLibrary()}
                />
                <StatTile
                  label="Projects"
                  value={projectCount}
                  onClick={() => goTo("projects")}
                />
                <StatTile
                  label="Marketplaces"
                  value={marketplacesCurrent ? marketplaceCount : "—"}
                  detail={
                    marketplacesCurrent
                      ? marketplaceCount === 0
                        ? "browse and subscribe"
                        : undefined
                      : // Not current and no error is the first read still on
                        // its way — the dash alone carries that; the failure
                        // note is for a read that answered it couldn't.
                        marketplacesError
                        ? MARKETPLACES_UNCHECKED_DETAIL
                        : undefined
                  }
                  onClick={() => goToMarketplaces()}
                />
              </div>
            ) : (
              <StatsSkeleton />
            )}
          </Section>
        </div>
      </div>
    </div>
  );
}
