import { useEffect, useMemo } from "react";
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
  PACKAGES_UNCHECKED_DETAIL,
  SCAN_AGAIN_LABEL,
  SCAN_FAILED_TITLE,
  SCAN_STALE_TITLE,
} from "@/lib/copy";
import { MARKETPLACES_UNCHECKED_DETAIL } from "@/lib/copy-marketplaces";
import { groupItems, installedCount, recentItems } from "@/lib/derive";
import { harnessName } from "@/lib/labels";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import {
  usePackageIndex,
  usePackagesKnown,
  usePackagesRead,
} from "@/lib/package-identity";
import { rescanEverything } from "@/lib/rescan";
import { availableUpdateCount } from "@/lib/update-groups";
import { cn } from "@/lib/utils";
import { useAuditOnMount, useAuditStore } from "@/stores/audit";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { useUpdatesStore } from "@/stores/updates";

const RECENT_ACTIVITY_LIMIT = 6;

export function OverviewPage() {
  // Home says whether anything needs attention, which is the audit's
  // answer as much as the scan's.
  useAuditOnMount();
  const { result, error, scanning } = useScanStore();
  // The audit read's own outcome, which is the only thing this row may
  // speak for: a failed remove or adopt is not a failed audit, and reaches
  // the person through the problems dialog instead.
  const auditError = useAuditStore((s) => s.read.error);
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
  const missingPackages = updateRows.filter((row) => row.filesMissing);
  const updatesError = useUpdatesStore((s) => s.read.error);
  // Only a landed read may put a number on the page. `rows` survives a
  // failed re-check as last-known facts, which is enough for the edited
  // row above and not enough for a count. Counted as updates and not as
  // news: the sidebar's badge stands for the Updates page's whole list,
  // this row's words promise an update to take.
  const updates = useUpdatesStore((s) =>
    s.read.status === "landed" ? availableUpdateCount(s.rows) : null,
  );
  const unreadable = useUpdatesStore((s) => s.unreadable);
  const goTo = useNavStore((s) => s.goTo);
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const goToMarketplaces = useNavStore((s) => s.goToMarketplaces);
  const marketplaceCount = useMarketplacesStore((s) => s.rows.length);
  // `rows` survives a failed re-read; only a landed read may put a number
  // — above all a zero — on the tile. A failed read is the failure to
  // note, while one still on its way is just the dash. The store's shared
  // `error` field is not consulted: writes clear it without making rows
  // current.
  const marketplacesCurrent = useMarketplacesStore(
    (s) => s.read.status === "landed",
  );
  const marketplacesLoaded = useMarketplacesStore(
    (s) => s.read.status !== "pending",
  );
  const loadMarketplaces = useMarketplacesStore((s) => s.load);
  useEffect(() => {
    void loadMarketplaces();
  }, [loadMarketplaces]);
  // Grouped once per scan: Recently changed and the Installed tile both
  // read these, and the page re-renders on six stores' writes.
  const packageOf = usePackageIndex();
  const packagesKnown = usePackagesKnown();
  const packagesRead = usePackagesRead();
  const groups = useMemo(
    () => (result && packageOf ? groupItems(result.items, packageOf) : []),
    [result, packageOf],
  );

  const scanAgain = (
    <Button
      size="sm"
      variant="outline"
      disabled={scanning}
      onClick={() => void rescanEverything({ announce: true })}
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
    missingPackages,
    result,
    updatesError,
    updates,
    unreadable,
    auditError,
    onProjects: () => goTo("projects"),
    onProblems: () => goTo("problems"),
    onUpdates: () => setPage("updates"),
    onEditedPackages: () => goToLibrary({ edited: true }),
    // The installed list, unnarrowed: each row marks the places missing
    // a file, and the row above already named them.
    onMissingPackages: () => goToLibrary({}),
    onPackage: (row) =>
      // An attention row is built from the update read, which speaks
      // declared packages.
      goToPackage({
        kind: row.kind,
        name: row.name,
        scope: row.scope,
        identity: "recorded",
      }),
    onAuditRetry: () => void auditRefresh({ force: true }),
  });

  const harnessNames = (result?.harnesses ?? [])
    .map((h) => harnessName(h.harness))
    .join(", ");
  const recent = recentItems(groups, RECENT_ACTIVITY_LIMIT);

  return (
    <div>
      <PageHeader title="Home" />
      <div className={PAGE_BODY}>
        <div className={cn("flex flex-col gap-10", CONTENT_WIDTH)}>
          {/* The store keeps the last good result so the page does not
              blank, but a re-scan that failed means everything below
              answers for the scan before it — said here once, over all of
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
              rather than standing there reporting its own emptiness. Only
              the scan is waited on. Every row this section can produce
              comes from the scan or the update check, bar the audit's own
              failure row, which appears when the audit reports — holding
              the whole list on the slowest read in the app would hide rows
              that were ready seconds earlier. */}
          {!result ? (
            <Section title="Needs attention">
              <AttentionSkeleton />
            </Section>
          ) : rows.length > 0 ? (
            <Section title="Needs attention">
              <AttentionSection rows={rows} />
            </Section>
          ) : null}

          <Section title="Recently changed">
            {/* Recently changed is a list of packages, so it waits on the
                same read the tile waits on: grouped against an answer
                about another scan it would show the duplicate names and
                kinds this page exists to be rid of, and its rows would
                narrow the Library to a kind they do not have. */}
            {result && packageOf ? (
              <RecentActivity groups={recent} />
            ) : (
              <RecentSkeleton />
            )}
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
                    click lands on, and only once the read that says which
                    installations are one package has answered. A number
                    taken before it would count installations under a label
                    that says packages; one kept from an earlier answer is
                    last-known, and says so rather than passing as current. */}
                <StatTile
                  label="Installed"
                  value={packagesKnown ? installedCount(groups) : null}
                  detail={
                    packagesRead.status === "failed"
                      ? PACKAGES_UNCHECKED_DETAIL
                      : undefined
                  }
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
