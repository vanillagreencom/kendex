import { useEffect } from "react";
import type { AvailablePackage, Catalog, Verdict } from "@/bindings";
import { StatusDot } from "@/components/status-dot";
import { TagBadges } from "@/components/tag-badge";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { safetyDotTitle } from "@/lib/copy-safety";
import { kindIcon } from "@/lib/kind-icon";
import { kindLabel, packageDisplayName } from "@/lib/labels";
import {
  catalogKey,
  catalogLabel,
  useMarketplacesStore,
} from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { safetyKey, usePreinstallSafety } from "@/stores/preinstall-safety";

/** One offered package with the catalog it comes from. */
export interface PackageEntry {
  catalog: Catalog;
  row: AvailablePackage;
}

const VERDICT_TONES: Record<Verdict, "good" | "warning" | "critical"> = {
  clean: "good",
  warn: "warning",
  block: "critical",
};

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
  return (
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
          />
        ))}
      </TableBody>
    </Table>
  );
}

function PackageRow({
  entry,
  showMarketplace,
}: {
  entry: PackageEntry;
  showMarketplace: boolean;
}) {
  const { catalog, row } = entry;
  const goToAvailablePackage = useNavStore((s) => s.goToAvailablePackage);
  const install = useMarketplacesStore((s) => s.install);
  const busy = useMarketplacesStore((s) => s.busy);
  const want = usePreinstallSafety((s) => s.want);
  const safety = usePreinstallSafety(
    (s) => s.scores[safetyKey(catalog, row.kind, row.name)],
  );
  const Icon = kindIcon(row.kind);

  useEffect(() => {
    want(catalog, row.kind, row.name);
  }, [want, catalog, row.kind, row.name]);

  const open = () =>
    goToAvailablePackage({ catalog, kind: row.kind, name: row.name });

  return (
    <TableRow className="cursor-pointer" onClick={open}>
      <TableCell>
        <div className="flex min-w-0 items-center gap-2.5">
          <Icon className="size-4 shrink-0 text-muted-foreground" />
          <div className="min-w-0">
            <div className="truncate font-medium">
              {packageDisplayName(row)}
            </div>
            {row.description ? (
              <div className="truncate text-xs text-muted-foreground">
                {row.description}
              </div>
            ) : null}
          </div>
        </div>
      </TableCell>
      <TableCell className="text-muted-foreground">
        {kindLabel(row.kind)}
      </TableCell>
      <TableCell>
        <TagBadges tags={row.tags} />
      </TableCell>
      {showMarketplace ? (
        <TableCell className="text-muted-foreground">
          {catalogLabel(catalog)}
        </TableCell>
      ) : null}
      <TableCell>
        {safety ? (
          <StatusDot
            className="inline-block"
            tone={VERDICT_TONES[safety.verdict]}
            title={safetyDotTitle(safety.verdict, safety.safety.score)}
          />
        ) : (
          <StatusDot className="inline-block" tone="muted" title="Checking…" />
        )}
      </TableCell>
      <TableCell className="text-right">
        {row.state === "installed" ? (
          <span className="text-xs text-muted-foreground">Installed</span>
        ) : row.state === "held-back-by-safety" ? (
          <span className="text-xs text-warning">Held back</span>
        ) : row.state === "not-offered" ? (
          <span className="text-xs text-muted-foreground">
            No longer offered
          </span>
        ) : catalog.by === "repo" ? (
          // Installing needs a subscription; the page's Subscribe button
          // is the one action, so the row only says the package is here.
          <span className="text-xs text-muted-foreground">Available</span>
        ) : (
          <Button
            size="sm"
            variant="outline"
            disabled={busy}
            onClick={(e) => {
              e.stopPropagation();
              void install({
                scope: catalog.scope,
                source: catalog.source,
                items: [{ kind: row.kind, name: row.name }],
              });
            }}
          >
            Install
          </Button>
        )}
      </TableCell>
    </TableRow>
  );
}
