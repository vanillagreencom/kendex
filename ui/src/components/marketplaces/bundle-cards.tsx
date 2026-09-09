import { Package } from "lucide-react";
import type { BundleDetail, Catalog, ItemKind, Scope } from "@/bindings";
import { InstalledIn } from "@/components/marketplaces/installed-in";
import { Card, CardContent } from "@/components/ui/card";
import { bundlePlaces } from "@/lib/installed-places";
import { kindLabel } from "@/lib/labels";
import { opensLabel, opensOnActivate } from "@/lib/opens-on-activate";
import { useNavStore } from "@/stores/nav";

/** The curated sets one marketplace offers, as cards: what each carries and
 * how much of it is already here. The sets are the catalog's own
 * declaration, so one whose members are not themselves offered still gets a
 * card, and "offers none" is only ever said about a read that landed. */
export function BundleCards({
  catalog,
  bundles,
  error,
  places,
}: {
  catalog: Catalog;
  bundles: BundleDetail[] | undefined;
  error: string | undefined;
  /** Where this marketplace's packages are installed, by kind and name —
   * `lib/installed-places.ts`. The page builds it once for the whole tab,
   * so a card neither scans the provenance join nor subscribes to it. */
  places: Map<string, Scope[]>;
}) {
  const goToBundle = useNavStore((s) => s.goToBundle);

  if (error) {
    return (
      <p className="py-16 text-center text-sm text-critical" role="alert">
        Its curated sets can't be read right now — {error}
      </p>
    );
  }

  if (!bundles) {
    return (
      <p className="py-16 text-center text-sm text-muted-foreground">
        Reading its curated sets…
      </p>
    );
  }

  if (bundles.length === 0) {
    return (
      <p className="py-16 text-center text-sm text-muted-foreground">
        This marketplace doesn't offer curated sets — its packages install one
        at a time from the Packages tab.
      </p>
    );
  }

  return (
    <div className="grid grid-cols-[repeat(auto-fill,minmax(18rem,1fr))] gap-4">
      {bundles.map((detail) => {
        const state =
          detail.installedMembers === detail.totalMembers &&
          detail.totalMembers > 0
            ? "Installed"
            : detail.installedMembers > 0
              ? `Partly installed (${detail.installedMembers} of ${detail.totalMembers})`
              : null;
        const open = () => goToBundle({ catalog, bundle: detail.name });
        return (
          // The card is the way in — a card that names a set opens that
          // set, so it carries no Open button of its own, and it opens on
          // the pointer and on Enter alike.
          <Card
            key={detail.name}
            {...opensOnActivate(open, opensLabel(detail.name))}
            className="cursor-pointer gap-0 py-0 transition-colors hover:bg-accent/40 hover:border-input"
          >
            <CardContent className="flex h-full flex-col gap-1.5 p-4">
              <div className="flex items-center gap-2">
                <Package className="size-4 shrink-0 text-muted-foreground" />
                {/* What a screen reader is told opens the set: a card
                    announces its content rather than an action. */}
                <button
                  type="button"
                  onClick={open}
                  className="min-w-0 cursor-pointer truncate text-sm font-medium hover:underline"
                >
                  {detail.name}
                </button>
              </div>
              {detail.description ? (
                <p className="line-clamp-2 text-[13px] text-muted-foreground">
                  {detail.description}
                </p>
              ) : null}
              {/* Quieter than the description and last in the card, because
                  it counts what the set holds rather than saying what the
                  set is for. */}
              <p className="mt-auto pt-1.5 text-xs text-muted-foreground">
                {memberSummary(detail.members)}
              </p>
              <div className="flex items-center justify-between gap-2 text-xs text-muted-foreground">
                <span className="truncate">{state}</span>
                {/* A control inside the card that does not open it: the
                    places this set is in are managed in those places, not
                    here. */}
                <InstalledIn
                  places={bundlePlaces(places, detail.members)}
                  standalone
                />
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
