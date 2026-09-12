import { type ReactNode, useCallback } from "react";
import type { Catalog, MarketplaceMeta, MarketplaceRow } from "@/bindings";
import { Ago } from "@/components/ago";
import { ExternalLink } from "@/components/external-link";
import { MarketplacePlaces } from "@/components/marketplaces/marketplace-places";
import { useCachedRead } from "@/components/marketplaces/use-catalog";
import { catalogRefusal } from "@/lib/catalog-read-state";
import {
  ABOUT_AUTHOR_LABEL,
  ABOUT_CONTAINS_LABEL,
  ABOUT_FINDINGS_TITLE,
  ABOUT_HOMEPAGE_LABEL,
  ABOUT_LICENSE_LABEL,
  ABOUT_NOTHING_SAID,
  ABOUT_UPDATED_LABEL,
  catalogContents,
  MARKETPLACE_NOT_DOWNLOADED,
  SOURCE_ALIAS_LABEL,
  SOURCE_LOCATION_LABEL,
} from "@/lib/copy-marketplaces";
import { KINDS, kindLabel } from "@/lib/labels";
import { marketplaceDisplay, sourceLine } from "@/lib/marketplace-display";
import {
  catalogKey,
  readErrorKey,
  useMarketplacesStore,
} from "@/stores/marketplaces";

/** The Contains line's parts, from the per-kind map the engine already
 * ships beside the catalog. Not summed here from the About report's
 * per-root rows: that report counts each declared root separately, while
 * the engine's map dedupes across them, so a catalog declaring one name
 * under two roots would have this line disagree with the Packages tab the
 * reader is looking at. */
function perKind(counts: { [key in string]: number }): string[] {
  // The app's own kind order, not the map's. `counts` arrives as a Rust
  // BTreeMap keyed by the wire name, so iterating it would put MCP servers
  // before skills — disagreeing with the Packages tab's filter sitting
  // beside this line, and for a serialization reason rather than a choice.
  return KINDS.filter((kind) => (counts[kind] ?? 0) > 0).map((kind) => {
    const count = counts[kind] ?? 0;
    return `${count} ${kindLabel(kind, count).toLowerCase()}`;
  });
}

/** When the catalog last changed, in the app's own coarse wording, with the
 * committer date itself on hover. A date that will not parse is left out
 * rather than shown as an interval from nowhere. */
function updatedLine(updatedAt: string | null): ReactNode {
  if (!updatedAt) return null;
  const at = Date.parse(updatedAt);
  if (Number.isNaN(at)) return null;
  return <Ago at={at} exact={updatedAt} />;
}

/** A block of labelled facts, one grid for the source's own details and one
 * for what the catalog says about itself. */
function Facts({ rows }: { rows: { label: string; value: ReactNode }[] }) {
  return (
    <dl className="grid grid-cols-[8rem_1fr] gap-x-4 gap-y-2 text-sm">
      {rows.map((row) => (
        <div key={row.label} className="contents">
          <dt className="text-muted-foreground">{row.label}</dt>
          <dd className="min-w-0 break-words">{row.value}</dd>
        </div>
      ))}
    </dl>
  );
}

/** The marketplace's profile and how this machine holds it: what the catalog
 * says about itself, when its content last moved, what it holds, anything
 * wrong with its own configuration — and, for a subscription, where its
 * bytes come from, the alias each place keys it under, and which projects
 * use it. Those last three are what a person reads before deciding whether
 * to unsubscribe, so they are on the page that offers it rather than behind
 * a tab of their own. */
export function AboutSection({
  catalog,
  row,
  identity,
  meta,
  counts,
}: {
  catalog: Catalog;
  /** The subscription row this page was opened as, where it has one — a
   * repository browsed before subscribing has none, and so has no alias, no
   * resolved folder and no places. */
  row: MarketplaceRow | null;
  /** What every place declaring this same marketplace is keyed by, from
   * `subscribed-grouping.ts::marketplaceIdentity`. Null for a repository
   * nobody subscribes to. */
  identity: string | null;
  meta: MarketplaceMeta | null;
  /** Packages offered by kind, as the engine counted them. Absent for a
   * catalog nothing has read yet, which leaves the Contains row out rather
   * than reporting a total nothing measured. */
  counts: { [key in string]: number } | null;
}) {
  const about = useMarketplacesStore((s) => s.about[catalogKey(catalog)]);
  const readError = useMarketplacesStore(
    (s) => s.readErrors[readErrorKey(catalogKey(catalog), "about")],
  );
  const loadAbout = useMarketplacesStore((s) => s.loadAbout);

  const readAbout = useCallback(() => loadAbout(catalog), [loadAbout, catalog]);
  useCachedRead(about !== undefined, !!readError, true, readAbout);

  // What this machine declares, which no read of the catalog can answer or
  // withhold: a source whose bytes cannot be read is exactly the one a
  // person is deciding whether to unsubscribe from, so its location, its
  // alias and the projects using it are drawn before the catalog's own
  // account and stand whatever that read did.
  const source = row ? marketplaceDisplay(row) : null;
  const details = (
    <>
      {source ? (
        <Facts
          rows={[
            { label: SOURCE_LOCATION_LABEL, value: sourceLine(source) },
            { label: SOURCE_ALIAS_LABEL, value: source.alias },
          ]}
        />
      ) : null}
      {identity ? <MarketplacePlaces identity={identity} /> : null}
    </>
  );

  const refused = catalogRefusal(readError);
  if (!about && refused) {
    return (
      <div className="max-w-3xl space-y-6">
        {details}
        {refused.is === "not-downloaded" ? (
          <p className="py-16 text-center text-sm text-muted-foreground">
            {MARKETPLACE_NOT_DOWNLOADED}
          </p>
        ) : (
          <p className="py-16 text-center text-sm text-critical" role="alert">
            This catalog can't be read right now — {refused.reason}
          </p>
        )}
      </div>
    );
  }
  if (!about) {
    return (
      <div className="max-w-3xl space-y-6">
        {details}
        <p className="py-16 text-center text-sm text-muted-foreground">
          Reading the catalog…
        </p>
      </div>
    );
  }

  const contains = catalogContents(perKind(counts ?? {}));
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
      {details}

      {empty ? (
        <p className="text-sm text-muted-foreground">{ABOUT_NOTHING_SAID}</p>
      ) : null}

      {meta?.description ? (
        <p className="text-sm leading-relaxed">{meta.description}</p>
      ) : null}

      {rows.length > 0 ? <Facts rows={rows} /> : null}

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
