// The vocabulary of places: every page id, the refs that address what a
// nested page is showing, and the snapshot the back stack keeps.
import type { Catalog, HarnessId, ItemKind, Scope } from "@/bindings";
import type { ScopeSelection } from "@/lib/derive";

export type Page =
  | "home"
  | "review"
  | "library"
  | "marketplaces"
  | "harnesses"
  | "projects"
  | "customize"
  // Reached from Home's attention list and the Review card's footnote —
  // adopting is an offer, not a sidebar destination.
  | "unmanaged"
  | "settings"
  | "updates"
  // Reached only from the status footer's problems segment or a review
  // card's "See all problems" — not in the sidebar, since it isn't a place
  // you'd navigate to when nothing is wrong.
  | "problems"
  // Reached only by opening a package from a list — which package is open
  // lives in `packageRef`, so the page is never a sidebar destination.
  | "package"
  // Nested under Marketplaces, reached only by opening a row — the open
  // thing lives in its ref, same shape as the package page.
  | "marketplaceDetail"
  | "bundleDetail"
  | "availablePackage";

/** Which of the Marketplaces page's four tabs is showing. */
export type MarketplacesTab = "subscribed" | "packages" | "community" | "mine";

/** What a link into the Library is asking to see — every narrowing it wants,
 * where to look included. A link states the whole thing, so a field it leaves
 * out is a narrowing it does not want, and an all-empty filter asks for
 * everything. */
export interface LibraryFilter {
  harness?: HarnessId;
  kind?: ItemKind;
  scope?: ScopeSelection;
}

/** The package a package page is showing — everything a backend query
 * needs to address it. */
export interface PackageRef {
  kind: ItemKind;
  name: string;
  scope: Scope;
}

/** One catalog, addressed the way every marketplace query is: a
 * subscription, or a repository opened from the Community tab before
 * subscribing. */
export type MarketplaceRef = Catalog;

/** One curated set inside a catalog. */
export interface BundleRef {
  catalog: Catalog;
  bundle: string;
}

/** One offered-but-not-installed package inside a catalog. */
export interface AvailableRef {
  catalog: Catalog;
  kind: ItemKind;
  name: string;
}

/** What the package page should open showing, when not its files — e.g.
 * "Preview" on the Updates page lands straight on the diff, and a Library
 * row's customized mark lands on what you changed in that place. Consumed
 * once by the page on mount, then cleared. */
export type PackageView =
  | { mode: "diff"; from: string; to: string }
  | { mode: "customize" };

/** Where the back button returns to: a page plus its state at push time. */
export interface HistoryEntry {
  page: Page;
  marketplacesTab: MarketplacesTab;
  packageRef: PackageRef | null;
  marketplaceRef: MarketplaceRef | null;
  bundleRef: BundleRef | null;
  availableRef: AvailableRef | null;
}
