import type { MarketplaceRow, Scope } from "@/bindings";
import {
  SEE_PROBLEMS_LABEL,
  unreadableRecordsLine,
  unreadableSourcesLine,
} from "@/lib/copy-marketplaces";
import { scopeLabel } from "@/lib/derive";
import { scopeName, scopeNames } from "@/lib/labels";
import { marketKey, readErrorKey } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";

/** One place the Packages tab could not fully answer for, and why.
 *
 * Keyed by place, not by marketplace alias: one alias subscribed in three
 * projects printed three identical lines naming nothing a reader could act
 * on. `sources` is a marketplace here that refused to load, so its packages
 * are missing from the table; `records` is this place's lock, which the
 * overview read reports for the place as a whole and the Problems page
 * explains. A place with both is named once, under `sources` — the missing
 * rows are the larger fact. */
export interface TroubledScope {
  key: string;
  scope: Scope;
  sources: boolean;
  records: boolean;
}

/** `records` is the subscription row's own `recordsUnreadable`, the answer
 * the overview read carried for the place the row lives in — not inferred
 * from the package rows and not joined from the update read. Inference
 * fails in exactly the case the line matters most: a place whose
 * marketplaces ALSO failed has no cached packages to carry the "unknown"
 * symptom, so it would get the sources line and no way to the reason. A
 * join fails on freshness: the update read runs on its own clock, so a
 * place registered since it last landed shows unknown rows under no line
 * at all. Carried on the row, the fact lands with the rows it describes. */
export function troubledScopes(
  rows: MarketplaceRow[],
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
    if (row.recordsUnreadable) place.records = true;
    const market = marketKey(row.scope, row.name);
    if (readErrors[readErrorKey(market, "packages")]) place.sources = true;
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
 * could not be read: one line per place, and — where the Problems page
 * carries the reason — the way to it. Names come from [scopeNames], so two
 * projects whose folders share a basename are told apart by their paths
 * rather than printing the same line twice. */
export function TroubleLines({ places }: { places: TroubledScope[] }) {
  if (places.length === 0) return null;
  const names = scopeNames(places.map((place) => place.scope));
  return (
    <div className="mb-3 space-y-1">
      {places.map((place, index) => (
        <p key={place.key} className="text-xs text-warning">
          {place.sources
            ? unreadableSourcesLine(names[index] ?? "")
            : unreadableRecordsLine(names[index] ?? "")}
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
