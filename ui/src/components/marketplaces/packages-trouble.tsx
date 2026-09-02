import type { AvailablePackage, MarketplaceRow, Scope } from "@/bindings";
import {
  SEE_PROBLEMS_LABEL,
  unreadableRecordsLine,
  unreadableSourcesLine,
} from "@/lib/copy-marketplaces";
import { scopeLabel } from "@/lib/derive";
import { recordsUnreadable } from "@/lib/install-state";
import { scopeName } from "@/lib/labels";
import { marketKey, readErrorKey } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";

/** One project the Packages tab could not fully answer for, and why.
 *
 * Keyed by project, not by marketplace alias: one alias subscribed in three
 * projects printed three identical lines naming nothing a reader could act
 * on. `sources` is a marketplace here that refused to load, so its packages
 * are missing from the table; `records` is this project's lock, which the
 * engine reports per row as an unknown installed state and the Problems
 * page explains. A project with both is named once, under `sources` — the
 * missing rows are the larger fact. */
export interface TroubledScope {
  key: string;
  scope: Scope;
  sources: boolean;
  records: boolean;
}

export function troubledScopes(
  rows: MarketplaceRow[],
  packages: Record<string, AvailablePackage[]>,
  readErrors: Record<string, string>,
): TroubledScope[] {
  const places = new Map<string, TroubledScope>();
  for (const row of rows) {
    if (!row.enabled) continue;
    const key = scopeLabel(row.scope);
    const place = places.get(key) ?? {
      key,
      scope: row.scope,
      sources: false,
      records: false,
    };
    const market = marketKey(row.scope, row.name);
    if (readErrors[readErrorKey(market, "packages")]) place.sources = true;
    if ((packages[market] ?? []).some((pkg) => recordsUnreadable(pkg.state))) {
      place.records = true;
    }
    if (place.sources || place.records) places.set(key, place);
  }
  return [...places.values()];
}

/** The way to the page that carries the reason and the way out, drawn the
 * same wherever an unreadable record is said: the tab's lines and the two
 * install pages below. */
export function SeeProblemsLink() {
  const goTo = useNavStore((s) => s.goTo);
  return (
    <button
      type="button"
      className="underline underline-offset-2 hover:no-underline"
      onClick={() => goTo("problems")}
    >
      {SEE_PROBLEMS_LABEL}
    </button>
  );
}

/** What an install page says in place of a button its scope's records
 * cannot stand behind. The Packages row already says "Not known" and sends
 * the reader here; a page reached from that row says the same rather than
 * leaving a live button to fail in the engine. */
export function RecordsUnreadableNote({ scope }: { scope: Scope }) {
  return (
    <p className="text-xs text-warning">
      {unreadableRecordsLine(scopeName(scope))} <SeeProblemsLink />
    </p>
  );
}

/** What the Packages tab says above its table when something under it
 * could not be read: one line per project, and — where the Problems page
 * carries the reason — the way to it. */
export function TroubleLines({ places }: { places: TroubledScope[] }) {
  if (places.length === 0) return null;
  return (
    <div className="mb-3 space-y-1">
      {places.map((place) => (
        <p key={place.key} className="text-xs text-warning">
          {place.sources
            ? unreadableSourcesLine(scopeName(place.scope))
            : unreadableRecordsLine(scopeName(place.scope))}
          {place.records ? (
            <>
              {" "}
              <SeeProblemsLink />
            </>
          ) : null}
        </p>
      ))}
    </div>
  );
}
