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
  SCAN_AGAIN_LABEL,
  SCAN_FAILED_TITLE,
  SCAN_STALE_TITLE,
} from "@/lib/copy";
import { MARKETPLACES_UNCHECKED_DETAIL } from "@/lib/copy-marketplaces";
import { groupItems, installedCount, recentItems } from "@/lib/derive";
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
  // The safety pass is the slowest thing the app does; until it has
  // ANSWERED once, Home cannot say whether anything needs attention — so
  // it says that it is still looking rather than showing an empty page. A
  // failed audit is an answer: the section renders what is known, with the
  // failure as a row of its own, instead of a skeleton for the session.
  const stillChecking = useAuditStore(
    (s) => s.auditedAt === null && s.checkError === null,
  );
  // `checkError`, not the store's shared `error`: item actions write the
  // shared field too, and a failed remove or adopt is not a failed audit.
  const auditError = useAuditStore((s) => s.checkError);
  const auditRefresh = useAuditStore((s) => s.refresh);
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
  // above all a zero — on the tile. `loaded` is whether any read has
  // answered at all: answered-but-not-current is the failure to note,
  // while not-yet-answered is just the dash. The store's shared `error`
  // field is not consulted — writes clear it without making rows current.
  const marketplacesCurrent = useMarketplacesStore((s) => s.rowsCurrent);
  const marketplacesLoaded = useMarketplacesStore((s) => s.loaded);
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
  if (!result && error !== null) {
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
    auditError,
    onReview: () => setPage("review"),
    onUnmanaged: () => goTo("unmanaged"),
    onProjects: () => goTo("projects"),
    onUpdates: () => setPage("updates"),
    onLibrary: () => goToLibrary(),
    onPackage: (row) =>
      goToPackage({ kind: row.kind, name: row.name, scope: row.scope }),
    onAuditRetry: () => void auditRefresh({ force: true }),
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
          {result && error !== null ? (
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
                {/* Counted in the Library's unit — packages, not
                    installations — so the number matches the table the
                    click lands on. */}
                <StatTile
                  label="Installed"
                  value={installedCount(result.items)}
                  onClick={() => goToLibrary()}
                />
                <StatTile
                  label="Projects"
                  value={projectCount}
                  onClick={() => goTo("projects")}
                />
                <StatTile
                  label="Marketplaces"
                  value={marketplacesCurrent ? marketplaceCount : null}
                  detail={
                    marketplacesCurrent
                      ? marketplaceCount === 0
                        ? "browse and subscribe"
                        : undefined
                      : // Answered but not current is a read that failed;
                        // not yet answered is the first read still on its
                        // way, and the dash alone carries that.
                        marketplacesLoaded
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
