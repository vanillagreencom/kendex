import type { PackageView } from "@/bindings";
import { DependencyFacts } from "@/components/marketplaces/package-dependencies";

/** The available-package page's facts column: where it comes from, the sets
 * that carry it, what it needs, and a name clash. The safety reading is not
 * here — score and findings are one block, and it sits in the main column
 * where there is room for the findings under the number. Neither are the
 * files: they read as a tree beside the file they open, which is the app's
 * one way to show files and needs the main column's width. */
export function AvailableAside({
  marketplace,
  repo,
  view,
  onOpenMarketplace,
  onOpenBundle,
}: {
  /** What the marketplace this package comes from is called —
   * `lib/marketplace-display.ts`, the same answer the breadcrumb above and
   * the marketplace's own page give. */
  marketplace: string;
  /** The repository or path behind the catalog, when known. */
  repo: string | null;
  view: PackageView | null;
  /** Open the marketplace this package comes from. */
  onOpenMarketplace: () => void;
  /** Open one of the curated sets that carry it. */
  onOpenBundle: (bundle: string) => void;
}) {
  return (
    <aside className="space-y-6 text-sm">
      <section>
        <h3 className="mb-1 text-xs font-semibold text-muted-foreground uppercase">
          From
        </h3>
        <p>
          {/* The name is what `lib/marketplace-display.ts` resolved, and
              it opens the marketplace it names. */}
          <button
            type="button"
            className="text-left hover:underline"
            onClick={onOpenMarketplace}
          >
            {marketplace}
          </button>
          {repo && repo !== marketplace ? (
            <span className="block truncate font-mono text-xs text-muted-foreground">
              {repo}
            </span>
          ) : null}
        </p>
      </section>
      {view && view.preview.bundles.length > 0 ? (
        <section>
          <h3 className="mb-1 text-xs font-semibold text-muted-foreground uppercase">
            Comes with
          </h3>
          {/* Each set's name opens that set. */}
          <p className="flex flex-wrap gap-x-1">
            {view.preview.bundles.map((bundle, index) => (
              <span key={bundle}>
                <button
                  type="button"
                  className="text-left hover:underline"
                  onClick={() => onOpenBundle(bundle)}
                >
                  {bundle}
                </button>
                {index < view.preview.bundles.length - 1 ? "," : ""}
              </span>
            ))}
          </p>
        </section>
      ) : null}
      {view ? (
        <DependencyFacts dependencies={view.preview.dependencies} />
      ) : null}
      {view?.preview.collision ? (
        <p className="text-xs text-warning">
          This name is already installed from {view.preview.collision}—
          installing from {marketplace} will be refused.
        </p>
      ) : null}
    </aside>
  );
}
