import type { Catalog, PackageView } from "@/bindings";
import { DependencyFacts } from "@/components/marketplaces/package-dependencies";
import { FileList } from "@/components/package/file-list";
import { catalogLabel } from "@/stores/marketplaces";

/** The available-package page's facts column: where it comes from, the sets
 * that carry it, what it needs, its files, and a name clash. The safety reading is not
 * here — score and findings are one block, and it sits in the main column
 * where there is room for the findings under the number. */
export function AvailableAside({
  catalog,
  repo,
  view,
  selectedFile,
  onSelectFile,
}: {
  catalog: Catalog;
  /** The repository or path behind the catalog, when known. */
  repo: string | null;
  view: PackageView | null;
  /** The file open in the main column; null shows the README. */
  selectedFile: string | null;
  onSelectFile: (path: string) => void;
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
      {view && view.preview.bundles.length > 0 ? (
        <section>
          <h3 className="mb-1 text-xs font-semibold text-muted-foreground uppercase">
            Comes with
          </h3>
          <p>{view.preview.bundles.join(", ")}</p>
        </section>
      ) : null}
      {view ? (
        <DependencyFacts dependencies={view.preview.dependencies} />
      ) : null}
      {view && view.preview.files.length > 0 ? (
        <section>
          <h3 className="mb-1 text-xs font-semibold text-muted-foreground uppercase">
            Files
          </h3>
          <FileList
            files={view.preview.files}
            selected={selectedFile}
            onSelect={onSelectFile}
          />
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
