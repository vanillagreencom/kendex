import {
  type Catalog,
  commands,
  type ItemKind,
  type ItemSource,
} from "@/bindings";
import { FileContent } from "@/components/package/file-preview";
import { StatusNote } from "@/components/status-note";
import { Skeleton } from "@/components/ui/skeleton";
import { useOrderedRead } from "@/lib/use-ordered-read";
import { catalogKey } from "@/stores/marketplaces";

/** One offered file of a package nobody has installed yet, rendered the
 * way the installed package page renders its files. */
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
  const state = useOrderedRead<ItemSource>(
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
      <StatusNote tone="critical" title="This file couldn't be shown">
        {state.error}
      </StatusNote>
    );
  }
  return <FileContent {...state.data} />;
}
