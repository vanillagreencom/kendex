import { useEffect } from "react";
import type { Catalog, MarketplaceMeta } from "@/bindings";
import { Badge } from "@/components/ui/badge";
import { kindLabel } from "@/lib/labels";
import {
  catalogKey,
  readErrorKey,
  useMarketplacesStore,
} from "@/stores/marketplaces";

const MODE_COPY: Record<string, string> = {
  "plugin-registry":
    "A plugin registry: the catalog's own manifest decides what it offers.",
  explicit: "This marketplace declares its layout in its own kendex.toml.",
  discovered:
    "No declared layout — kendex found its skills in the conventional folders.",
  unusable:
    "The catalog's own configuration can't be read, so nothing is offered.",
};

/** What the catalog says about itself: how its items were decided, what was
 * found where, and every finding it carries — the same report `kendex
 * index` prints. */
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

  useEffect(() => {
    void loadAbout(catalog);
  }, [catalog, loadAbout]);

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

  return (
    <div className="max-w-3xl space-y-6">
      {meta?.homepage || meta?.tags?.length ? (
        <div className="flex flex-wrap items-center gap-2">
          {meta?.homepage ? (
            <a
              className="text-sm text-info underline-offset-2 hover:underline"
              href={meta.homepage}
              target="_blank"
              rel="noreferrer"
            >
              {meta.homepage}
            </a>
          ) : null}
          {(meta?.tags ?? []).map((tag) => (
            <Badge key={tag} variant="secondary">
              {tag}
            </Badge>
          ))}
        </div>
      ) : null}

      <section>
        <h3 className="mb-1 text-sm font-semibold">How it's read</h3>
        <p className="text-sm text-muted-foreground">
          {MODE_COPY[about.mode] ?? about.mode}
        </p>
      </section>

      {about.found.length > 0 ? (
        <section>
          <h3 className="mb-2 text-sm font-semibold">What was found</h3>
          <div className="divide-y rounded-lg border text-sm">
            {about.found.map((row) => (
              <div
                key={`${row.root}:${row.kind}`}
                className="flex items-center justify-between px-3 py-2"
              >
                <span className="font-mono text-xs">{row.root}</span>
                <span className="text-muted-foreground">
                  {row.count} {kindLabel(row.kind, row.count).toLowerCase()}
                </span>
              </div>
            ))}
          </div>
        </section>
      ) : null}

      {about.findings.length > 0 ? (
        <section>
          <h3 className="mb-2 text-sm font-semibold">
            Things the catalog gets wrong
          </h3>
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
      ) : (
        <p className="text-sm text-muted-foreground">
          Nothing wrong with this catalog.
        </p>
      )}
    </div>
  );
}
