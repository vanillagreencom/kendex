import { type ReactNode, useCallback } from "react";
import type {
  AboutFound,
  Catalog,
  ItemKind,
  MarketplaceMeta,
} from "@/bindings";
import { ExternalLink } from "@/components/external-link";
import { useCachedRead } from "@/components/marketplaces/use-catalog";
import {
  ABOUT_AUTHOR_LABEL,
  ABOUT_CONTAINS_LABEL,
  ABOUT_FINDINGS_TITLE,
  ABOUT_HOMEPAGE_LABEL,
  ABOUT_LICENSE_LABEL,
  ABOUT_NOTHING_SAID,
  ABOUT_UPDATED_LABEL,
  catalogContents,
} from "@/lib/copy-marketplaces";
import { kindLabel } from "@/lib/labels";
import { relativeTime } from "@/lib/relative-time";
import {
  catalogKey,
  readErrorKey,
  useMarketplacesStore,
} from "@/stores/marketplaces";

/** The per-kind totals behind the Contains line. The report counts each
 * root separately because a catalog may keep one kind in several folders;
 * where the folders are is the catalog author's business, so the tab adds
 * them up and names the kind once. */
function perKind(found: AboutFound[]): string[] {
  const totals = new Map<ItemKind, number>();
  for (const row of found) {
    totals.set(row.kind, (totals.get(row.kind) ?? 0) + row.count);
  }
  return [...totals].map(
    ([kind, count]) => `${count} ${kindLabel(kind, count).toLowerCase()}`,
  );
}

/** When the catalog last changed, in the app's own coarse wording, with the
 * committer date itself on hover. A date that will not parse is left out
 * rather than shown as an interval from nowhere. */
function updatedLine(updatedAt: string | null): ReactNode {
  if (!updatedAt) return null;
  const at = Date.parse(updatedAt);
  if (Number.isNaN(at)) return null;
  return <span title={updatedAt}>{relativeTime(at, Date.now())}</span>;
}

/** The marketplace's profile: what the catalog says about itself, when its
 * content last moved, what it holds, and anything wrong with its own
 * configuration. Nothing here describes how kendex read it — the header
 * carries the name, the links and the tags, and this tab carries the rest. */
export function AboutSection({
  catalog,
  meta,
}: {
  catalog: Catalog;
  meta: MarketplaceMeta | null;
}) {
  const about = useMarketplacesStore((s) => s.about[catalogKey(catalog)]);
  const readError = useMarketplacesStore(
    (s) => s.readErrors[readErrorKey(catalogKey(catalog), "about")],
  );
  const loadAbout = useMarketplacesStore((s) => s.loadAbout);

  const readAbout = useCallback(() => loadAbout(catalog), [loadAbout, catalog]);
  useCachedRead(about !== undefined, !!readError, true, readAbout);

  if (!about && readError) {
    return (
      <p className="py-16 text-center text-sm text-critical" role="alert">
        This catalog can't be read right now — {readError}
      </p>
    );
  }
  if (!about) {
    return (
      <p className="py-16 text-center text-sm text-muted-foreground">
        Reading the catalog…
      </p>
    );
  }

  const contains = catalogContents(perKind(about.found));
  const rows: { label: string; value: ReactNode }[] = [
    { label: ABOUT_AUTHOR_LABEL, value: meta?.author ?? null },
    { label: ABOUT_LICENSE_LABEL, value: meta?.license ?? null },
    {
      label: ABOUT_HOMEPAGE_LABEL,
      value: meta?.homepage ? (
        <ExternalLink url={meta.homepage}>{meta.homepage}</ExternalLink>
      ) : null,
    },
    { label: ABOUT_UPDATED_LABEL, value: updatedLine(about.updatedAt) },
    { label: ABOUT_CONTAINS_LABEL, value: contains },
  ].filter((row) => row.value !== null && row.value !== "");

  const empty =
    !meta?.description && rows.length === 0 && about.findings.length === 0;

  return (
    <div className="max-w-3xl space-y-6">
      {empty ? (
        <p className="text-sm text-muted-foreground">{ABOUT_NOTHING_SAID}</p>
      ) : null}

      {meta?.description ? (
        <p className="text-sm leading-relaxed">{meta.description}</p>
      ) : null}

      {rows.length > 0 ? (
        <dl className="grid grid-cols-[8rem_1fr] gap-x-4 gap-y-2 text-sm">
          {rows.map((row) => (
            <div key={row.label} className="contents">
              <dt className="text-muted-foreground">{row.label}</dt>
              <dd className="min-w-0 break-words">{row.value}</dd>
            </div>
          ))}
        </dl>
      ) : null}

      {about.findings.length > 0 ? (
        <section>
          <h3 className="mb-2 text-sm font-semibold">{ABOUT_FINDINGS_TITLE}</h3>
          <div className="space-y-3">
            {about.findings.map((finding) => (
              <div
                key={`${finding.location}:${finding.problem}`}
                className="rounded-lg border p-3 text-sm"
              >
                <p className="font-mono text-xs text-muted-foreground">
                  {finding.location}
                </p>
                <p className="mt-1">{finding.problem}</p>
                <p className="mt-1 text-xs text-muted-foreground">
                  Fix: {finding.fix}
                </p>
              </div>
            ))}
          </div>
        </section>
      ) : null}
    </div>
  );
}
