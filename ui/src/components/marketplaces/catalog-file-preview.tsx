import {
  type Catalog,
  commands,
  type ItemKind,
  type ItemSource,
  type SourceReadRefused,
} from "@/bindings";
import { FilePane } from "@/components/files/file-pane";
import { StatusNote } from "@/components/status-note";
import { Skeleton } from "@/components/ui/skeleton";
import { catalogRefusalLine } from "@/lib/catalog-read-state";
import { FILE_READ_FAILED_TITLE } from "@/lib/copy-files";
import { useOrderedRead } from "@/lib/use-ordered-read";
import { catalogKey } from "@/stores/marketplaces";

/** One offered file of a package nobody has installed yet, read and then
 * drawn in the app's one file pane — the same pane the installed package's
 * Files tab draws. */
export function CatalogFilePreview({
  catalog,
  kind,
  name,
  path,
}: {
  catalog: Catalog;
  kind: ItemKind;
  name: string;
  path: string;
}) {
  const state = useOrderedRead<ItemSource, SourceReadRefused>(
    `${catalogKey(catalog)}::${kind}::${name}::${path}`,
    () => commands.marketplacePackageFile(catalog, kind, name, path),
  );

  if (state.status === "loading") {
    return (
      <div className="space-y-2">
        <Skeleton className="h-3.5 w-3/4" />
        <Skeleton className="h-3.5 w-full" />
        <Skeleton className="h-3.5 w-2/3" />
      </div>
    );
  }
  if (state.status === "error") {
    return (
      <StatusNote tone="critical" title={FILE_READ_FAILED_TITLE}>
        {catalogRefusalLine(state.error)}
      </StatusNote>
    );
  }
  return <FilePane {...state.data} />;
}
