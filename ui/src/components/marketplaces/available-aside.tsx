import type { Catalog, PackageView } from "@/bindings";
import { fileSizeLabel } from "@/components/package/file-list";
import { VERDICT_LABELS } from "@/lib/labels";
import { catalogLabel } from "@/stores/marketplaces";

/** The available-package page's facts column: where it comes from, its
 * safety score, the sets that carry it, its files, and a name clash. */
export function AvailableAside({
  catalog,
  repo,
  view,
}: {
  catalog: Catalog;
  /** The repository or path behind the catalog, when known. */
  repo: string | null;
  view: PackageView | null;
}) {
  return (
    <aside className="space-y-6 text-sm">
      <section>
        <h3 className="mb-1 text-xs font-semibold text-muted-foreground uppercase">
          From
        </h3>
        <p>
          {catalogLabel(catalog)}
          {repo && repo !== catalogLabel(catalog) ? (
            <span className="block truncate font-mono text-xs text-muted-foreground">
              {repo}
            </span>
          ) : null}
        </p>
      </section>
      {view ? (
        <section>
          <h3 className="mb-1 text-xs font-semibold text-muted-foreground uppercase">
            Safety
          </h3>
          <p>
            {VERDICT_LABELS[view.safety.verdict]} · {view.safety.safety.score}
            /100
          </p>
        </section>
      ) : null}
      {view && view.preview.bundles.length > 0 ? (
        <section>
          <h3 className="mb-1 text-xs font-semibold text-muted-foreground uppercase">
            Comes with
          </h3>
          <p>{view.preview.bundles.join(", ")}</p>
        </section>
      ) : null}
      {view && view.preview.files.length > 0 ? (
        <section>
          <h3 className="mb-1 text-xs font-semibold text-muted-foreground uppercase">
            Files
          </h3>
          <ul className="space-y-1">
            {view.preview.files.map((file) => (
              <li
                key={file.path}
                className="flex items-baseline justify-between gap-2"
              >
                <span className="truncate font-mono text-xs">{file.path}</span>
                <span className="shrink-0 text-xs text-muted-foreground">
                  {fileSizeLabel(file.size)}
                </span>
              </li>
            ))}
          </ul>
        </section>
      ) : null}
      {view?.preview.collision ? (
        <p className="text-xs text-warning">
          This name is already installed from {view.preview.collision}—
          installing from {catalogLabel(catalog)} will be refused.
        </p>
      ) : null}
    </aside>
  );
}
