import { useEffect } from "react";
import {
  type AttentionRow,
  AttentionSection,
} from "@/components/home/attention-section";
import {
  AttentionSkeleton,
  RecentSkeleton,
  StatsSkeleton,
} from "@/components/home/home-skeletons";
import { RecentActivity } from "@/components/home/recent-activity";
import { PageHeader } from "@/components/page-header";
import { Section } from "@/components/section";
import { StatTile } from "@/components/stat-tile";
import { auditCounts } from "@/lib/audit-counts";
import {
  FORKED_ATTENTION_DETAIL,
  forkedAttentionTitle,
  REVIEW_ACTION_LABEL,
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
  const { result } = useScanStore();
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
  const editedPackages = updateRows.filter((row) => row.blockedByLocalEdit);
  const goTo = useNavStore((s) => s.goTo);
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const goToMarketplaces = useNavStore((s) => s.goToMarketplaces);
  const marketplaceCount = useMarketplacesStore((s) => s.rows.length);
  const loadMarketplaces = useMarketplacesStore((s) => s.load);
  useEffect(() => {
    void loadMarketplaces();
  }, [loadMarketplaces]);

  const {
    changes: actionableCount,
    inTheWay,
    unmanaged: unmanagedCount,
    blocked,
    open,
  } = auditCounts(views);
  const missing = result?.missingProjects ?? [];

  const rows: AttentionRow[] = [];
  if (editedPackages.length > 0) {
    const first = editedPackages[0];
    rows.push({
      key: "edited",
      tone: "warning",
      title: forkedAttentionTitle(editedPackages.length),
      detail: FORKED_ATTENTION_DETAIL,
      action:
        editedPackages.length === 1 && first
          ? {
              label: first.name,
              onClick: () =>
                goToPackage({
                  kind: first.kind,
                  name: first.name,
                  scope: first.scope,
                }),
            }
          : { label: "Library", onClick: () => setPage("library") },
    });
  }
  if (blocked > 0) {
    rows.push({
      key: "safety",
      tone: "critical",
      title: blocked === 1 ? "1 problem found" : `${blocked} problems found`,
      detail: "Held back until you accept them.",
      action: { label: REVIEW_ACTION_LABEL, onClick: () => setPage("review") },
    });
  }
  if (open > 0) {
    rows.push({
      key: "decisions",
      tone: "warning",
      title: open === 1 ? "1 finding to review" : `${open} findings to review`,
      detail: "In content already installed.",
      action: { label: REVIEW_ACTION_LABEL, onClick: () => setPage("review") },
    });
  }
  if (inTheWay > 0) {
    rows.push({
      key: "in-the-way",
      tone: "warning",
      title:
        inTheWay === 1
          ? "1 item needs your decision"
          : `${inTheWay} items need your decision`,
      detail: "Files are already where they go.",
      action: { label: REVIEW_ACTION_LABEL, onClick: () => setPage("review") },
    });
  }
  if (actionableCount > 0) {
    rows.push({
      key: "drift",
      tone: "info",
      title:
        actionableCount === 1
          ? "1 change ready to apply"
          : `${actionableCount} changes ready to apply`,
      action: { label: REVIEW_ACTION_LABEL, onClick: () => setPage("review") },
    });
  }
  if (unmanagedCount > 0) {
    rows.push({
      key: "unmanaged",
      tone: "muted",
      title:
        unmanagedCount === 1
          ? "1 unmanaged item"
          : `${unmanagedCount} unmanaged items`,
      detail: "kendex didn't put them there.",
      action: { label: "Review", onClick: () => goTo("unmanaged") },
    });
  }
  if (missing.length > 0) {
    rows.push({
      key: "missing-projects",
      tone: "warning",
      title:
        missing.length === 1
          ? "1 project folder can't be found"
          : `${missing.length} project folders can't be found`,
      detail:
        missing.length === 1
          ? `We can't find ${missing[0]}. If you moved it, add it again.`
          : "If you moved these, add them again from Harnesses & Projects.",
      action: {
        label: "Projects",
        onClick: () => goTo("projects"),
      },
    });
  }
  if (result && result.warnings.length > 0) {
    rows.push({
      key: "warnings",
      tone: "warning",
      title:
        result.warnings.length === 1
          ? "1 file couldn't be read"
          : `${result.warnings.length} files couldn't be read`,
      detail: result.warnings[0],
    });
  }

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
                  value={marketplaceCount}
                  detail={
                    marketplaceCount === 0 ? "browse and subscribe" : undefined
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
