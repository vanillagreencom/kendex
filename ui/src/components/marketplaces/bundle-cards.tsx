import { Package } from "lucide-react";
import { useEffect, useMemo } from "react";
import type { AvailablePackage, Catalog, ItemKind } from "@/bindings";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { kindLabel } from "@/lib/labels";
import { bundleKey, useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";

/** The curated sets one marketplace offers, as cards: what each carries and
 * how much of it is already here. The names come off the offered packages —
 * every member names its sets — and each card's counts come from its own
 * bundle read. */
export function BundleCards({
  catalog,
  offered,
}: {
  catalog: Catalog;
  offered: AvailablePackage[];
}) {
  const bundles = useMarketplacesStore((s) => s.bundles);
  const loadBundle = useMarketplacesStore((s) => s.loadBundle);
  const goToBundle = useNavStore((s) => s.goToBundle);

  const names = useMemo(
    () => [...new Set(offered.flatMap((pkg) => pkg.bundles))].sort(),
    [offered],
  );

  useEffect(() => {
    for (const name of names) {
      void loadBundle(catalog, name);
    }
  }, [names, catalog, loadBundle]);

  if (names.length === 0) {
    return (
      <p className="py-16 text-center text-sm text-muted-foreground">
        This marketplace doesn't offer curated sets — its packages install one
        at a time from the Packages tab.
      </p>
    );
  }

  return (
    <div className="grid grid-cols-[repeat(auto-fill,minmax(18rem,1fr))] gap-4">
      {names.map((name) => {
        const detail = bundles[bundleKey(catalog, name)];
        const state = !detail
          ? null
          : detail.installedMembers === detail.totalMembers &&
              detail.totalMembers > 0
            ? "Installed"
            : detail.installedMembers > 0
              ? `Partly installed (${detail.installedMembers} of ${detail.totalMembers})`
              : null;
        return (
          <Card key={name}>
            <CardContent className="flex h-full flex-col gap-2 p-4">
              <div className="flex items-center gap-2">
                <Package className="size-4 shrink-0 text-muted-foreground" />
                <span className="min-w-0 truncate font-medium">{name}</span>
              </div>
              {detail?.description ? (
                <p className="line-clamp-2 text-xs text-muted-foreground">
                  {detail.description}
                </p>
              ) : null}
              <p className="text-xs text-muted-foreground">
                {detail ? memberSummary(detail.members) : "…"}
              </p>
              <div className="mt-auto flex items-center justify-between pt-1">
                <span className="text-xs text-muted-foreground">{state}</span>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => goToBundle({ catalog, bundle: name })}
                >
                  Open
                </Button>
              </div>
            </CardContent>
          </Card>
        );
      })}
    </div>
  );
}

/** "3 skills · 1 agent · 1 hook" — counts by kind, kinds in member order. */
function memberSummary(members: { kind: ItemKind }[]): string {
  const counts = new Map<ItemKind, number>();
  for (const member of members) {
    counts.set(member.kind, (counts.get(member.kind) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([kind, count]) => `${count} ${kindLabel(kind, count).toLowerCase()}`)
    .join(" · ");
}
