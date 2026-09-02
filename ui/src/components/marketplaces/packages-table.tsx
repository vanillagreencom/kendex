import {
  type PackageEntry,
  PackageRow,
} from "@/components/marketplaces/package-row";
import { useRepoKey } from "@/components/marketplaces/repo-action";
import {
  Table,
  TableBody,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { SUBSCRIBE_TO_INSTALL_MEANS } from "@/lib/copy-marketplaces";
import {
  catalogKey,
  repoAction,
  useMarketplacesStore,
} from "@/stores/marketplaces";

export type { PackageEntry } from "@/components/marketplaces/package-row";

/** The one table of offered packages — the Packages tab across every
 * subscription and a marketplace detail's own list are both this. */
export function PackagesTable({
  entries,
  showMarketplace,
}: {
  entries: PackageEntry[];
  /** The cross-marketplace tab names each row's source; a single
   * marketplace's own page already says it once at the top. */
  showMarketplace: boolean;
}) {
  // A bare repository's table is one catalog's; the cross-marketplace tab
  // only ever carries subscriptions. So what the repository offers is
  // decided once for the table, from the same key and the same
  // `repoAction` the page header reads — a cell deciding for itself
  // offered a Subscribe the engine refuses whenever a switched-off
  // subscription already declared the repository. It also says the
  // sentence once: the tooltip it replaces was the same constant rendered
  // per row.
  const browsing = entries.find((entry) => entry.catalog.by === "repo");
  const repo = browsing?.catalog.by === "repo" ? browsing.catalog.repo : "";
  const rows = useMarketplacesStore((s) => s.rows);
  const read = useMarketplacesStore((s) => s.read);
  const summary = useMarketplacesStore(
    (s) => s.summaries[catalogKey({ by: "repo", repo })] ?? null,
  );
  const repoKey = useRepoKey(repo, summary);
  const { kind } = repoAction(rows, read, repoKey);
  // Only an undeclared repository can be subscribed from a row. A declared
  // one — switched off, or unreadable — is the header's Turn on or
  // Refresh, and a second control here would race it.
  const offerSubscribe = repo !== "" && kind === "subscribe";

  return (
    <>
      {offerSubscribe ? (
        <p className="mb-3 text-xs text-muted-foreground">
          {SUBSCRIBE_TO_INSTALL_MEANS}
        </p>
      ) : null}
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Name</TableHead>
            <TableHead className="w-28">Type</TableHead>
            <TableHead className="w-48">For</TableHead>
            {showMarketplace ? (
              <TableHead className="w-40">Marketplace</TableHead>
            ) : null}
            <TableHead className="w-20">Safety</TableHead>
            <TableHead className="w-32 text-right">Status</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {entries.map((entry) => (
            <PackageRow
              key={`${catalogKey(entry.catalog)}:${entry.row.kind}:${entry.row.name}`}
              entry={entry}
              showMarketplace={showMarketplace}
              offerSubscribe={offerSubscribe}
            />
          ))}
        </TableBody>
      </Table>
    </>
  );
}
