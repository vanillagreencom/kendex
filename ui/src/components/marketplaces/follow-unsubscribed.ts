import { useEffect, useRef } from "react";
import type { Catalog, MarketplaceRow } from "@/bindings";
import {
  marketplaceIdentity,
  openPlace,
  personalFirst,
} from "@/components/marketplaces/subscribed-grouping";
import { subscription, useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";

/** Unsubscribing from the Projects section can remove the very place the
 *  detail page opened as. The row goes, and with it the tab the person was
 *  reading — so the page follows the marketplace to another place still
 *  holding it, or leaves for the list when none does. The identity has to
 *  outlive the row to do that, and only a read that landed may be taken as
 *  proof the place is gone: rows are empty before the first read and after
 *  a failed one, and neither is an unsubscribe. */
export function useFollowUnsubscribed(
  catalog: Catalog,
  row: MarketplaceRow | undefined,
  identity: string | null,
): void {
  const rows = useMarketplacesStore((s) => s.rows);
  const read = useMarketplacesStore((s) => s.read);
  const goToMarketplace = useNavStore((s) => s.goToMarketplace);
  const leaveMarketplace = useNavStore((s) => s.leaveMarketplace);
  const lastIdentity = useRef<string | null>(null);
  useEffect(() => {
    if (identity) lastIdentity.current = identity;
  }, [identity]);
  useEffect(() => {
    if (catalog.by !== "subscription" || row || read.status !== "landed")
      return;
    const held = lastIdentity.current;
    if (!held) return;
    // The same pick the card makes, from the same helper: a place actually
    // offering packages, personal before a project. First-in-overview-order
    // would land the reader on a switched-off place.
    const elsewhere = openPlace(
      rows.filter((r) => marketplaceIdentity(r) === held).sort(personalFirst),
    );
    if (elsewhere) {
      goToMarketplace(subscription(elsewhere.scope, elsewhere.name));
    } else {
      // Left, not navigated away from: this page is a subscription that no
      // longer exists, so it must not be somewhere Back can return to.
      leaveMarketplace("subscribed");
    }
  }, [catalog, row, read.status, rows, goToMarketplace, leaveMarketplace]);
}
