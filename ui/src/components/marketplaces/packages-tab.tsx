import { Search } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import type { ItemKind, Tag } from "@/bindings";
import type { PackageEntry } from "@/components/marketplaces/package-row";
import { Filter } from "@/components/marketplaces/packages-filter";
import { PackagesTable } from "@/components/marketplaces/packages-table";
import {
  TroubleLines,
  troubledScopes,
} from "@/components/marketplaces/packages-trouble";
import { Input } from "@/components/ui/input";
import { SelectItem } from "@/components/ui/select";
import { scopeLabel } from "@/lib/derive";
import {
  KINDS,
  kindLabel,
  packageDisplayName,
  scopeName,
  TAG_LABELS,
} from "@/lib/labels";
import { PAGE_BODY, PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";
import {
  marketKey,
  subscription,
  useMarketplacesStore,
} from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";

const TAGS = Object.keys(TAG_LABELS) as Tag[];

/** One searchable table across every subscribed marketplace. `Where` is the
 * destination a package installs to — each row installs into the scope its
 * subscription lives in, so the filter narrows by that. */
export function PackagesTab() {
  const rows = useMarketplacesStore((s) => s.rows);
  const packages = useMarketplacesStore((s) => s.packages);
  const readErrors = useMarketplacesStore((s) => s.readErrors);
  const loadPackages = useMarketplacesStore((s) => s.loadPackages);
  const searchFocus = useNavStore((s) => s.searchFocus);
  const searchRef = useRef<HTMLInputElement>(null);
  const [search, setSearch] = useState("");
  const [kind, setKind] = useState("any");
  const [tag, setTag] = useState("any");
  const [marketplace, setMarketplace] = useState("any");
  const [where, setWhere] = useState("any");

  // Every enabled subscription's offer lands in the shared cache; a
  // subscription that cannot be read simply contributes no rows yet.
  useEffect(() => {
    for (const row of rows) {
      if (!row.enabled) continue;
      if (!packages[marketKey(row.scope, row.name)]) {
        void loadPackages(subscription(row.scope, row.name));
      }
    }
  }, [rows, packages, loadPackages]);

  useEffect(() => {
    if (searchFocus === 0) return;
    searchRef.current?.focus();
  }, [searchFocus]);

  const entries = useMemo(() => {
    const out: PackageEntry[] = [];
    for (const row of rows) {
      if (!row.enabled) continue;
      if (marketplace !== "any" && row.name !== marketplace) continue;
      if (where !== "any" && scopeLabel(row.scope) !== where) continue;
      for (const pkg of packages[marketKey(row.scope, row.name)] ?? []) {
        if (kind !== "any" && pkg.kind !== kind) continue;
        if (tag !== "any" && !pkg.tags.includes(tag as Tag)) continue;
        const needle = search.trim().toLowerCase();
        if (
          needle &&
          !pkg.name.toLowerCase().includes(needle) &&
          !(pkg.summary ?? "").toLowerCase().includes(needle)
        )
          continue;
        out.push({
          catalog: subscription(row.scope, row.name),
          row: pkg,
          recordsUnreadable: row.recordsUnreadable,
          revision: row.rev ?? row.commit,
        });
      }
    }
    // Ordered by name. Popularity is what this list wants to lead with, and
    // nothing the app receives carries one: neither a subscription's
    // catalog nor the kendex.ai directory index publishes installs, stars
    // or a per-package timestamp, so any "most installed" order here would
    // be invented. Name is the order that is true today; the moment the
    // registry publishes a count, it belongs in front of this comparison.
    //
    // Compared through the same formatter the cell renders. A hook's
    // identifier is "<event>:<matcher>:<name>" and the column shows only
    // the trailing name, so sorting the raw identifier put a hook spelled
    // "PreToolUse:*:alpha" among the Ps while the reader saw "alpha".
    return out.sort((a, b) =>
      packageDisplayName(a.row).localeCompare(packageDisplayName(b.row)),
    );
  }, [rows, packages, search, kind, tag, marketplace, where]);

  // Named above the table so an empty offer is never mistaken for an empty
  // marketplace, and so a row saying nothing about its installed state says
  // why. One line per place — see [troubledScopes].
  const troubled = useMemo(
    () => troubledScopes(rows, readErrors),
    [rows, readErrors],
  );
  const marketplaceNames = [...new Set(rows.map((row) => row.name))];
  const whereOptions = [
    ...new Map(rows.map((row) => [scopeLabel(row.scope), row.scope])).values(),
  ];

  return (
    <>
      <div className={cn("pb-3", PAGE_GUTTER)}>
        <div
          className={cn(
            WIDE_CONTENT_WIDTH,
            "flex flex-wrap items-center gap-2",
          )}
        >
          <div className="relative min-w-56 flex-1">
            <Search className="absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              ref={searchRef}
              className="pl-8"
              placeholder="Search packages"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
          <Filter
            value={kind}
            onChange={setKind}
            label="Type"
            display={(v) => kindLabel(v as ItemKind)}
          >
            {KINDS.map((k) => (
              <SelectItem key={k} value={k}>
                {kindLabel(k)}
              </SelectItem>
            ))}
          </Filter>
          <Filter
            value={tag}
            onChange={setTag}
            label="For"
            display={(v) => TAG_LABELS[v as Tag]}
          >
            {TAGS.map((t) => (
              <SelectItem key={t} value={t}>
                {TAG_LABELS[t]}
              </SelectItem>
            ))}
          </Filter>
          <Filter
            value={marketplace}
            onChange={setMarketplace}
            label="Marketplace"
            display={(v) => v}
          >
            {marketplaceNames.map((name) => (
              <SelectItem key={name} value={name}>
                {name}
              </SelectItem>
            ))}
          </Filter>
          <Filter
            value={where}
            onChange={setWhere}
            label="Where"
            display={(v) =>
              scopeName(
                whereOptions.find((s) => scopeLabel(s) === v) ?? {
                  scope: "project",
                  root: v,
                },
              )
            }
          >
            {whereOptions.map((scope) => (
              <SelectItem key={scopeLabel(scope)} value={scopeLabel(scope)}>
                {scopeName(scope)}
              </SelectItem>
            ))}
          </Filter>
          <span className="ml-auto text-xs whitespace-nowrap text-muted-foreground tabular-nums">
            {entries.length} package{entries.length === 1 ? "" : "s"}
          </span>
        </div>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className={cn(PAGE_BODY, "pt-0")}>
          <div className={WIDE_CONTENT_WIDTH}>
            <TroubleLines places={troubled} />
            {entries.length === 0 ? (
              <p className="py-16 text-center text-sm text-muted-foreground">
                {rows.length === 0
                  ? "Subscribe to a marketplace to browse its packages here."
                  : "Nothing matches — clear a filter or try another search."}
              </p>
            ) : (
              <PackagesTable entries={entries} showMarketplace />
            )}
          </div>
        </div>
      </div>
    </>
  );
}
