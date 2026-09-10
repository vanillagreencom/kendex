// The vocabulary of places: every page id, the refs that address what a
// nested page is showing, and the snapshot the back stack keeps.
import type { Catalog, ItemKind, Scope } from "@/bindings";
import type { ItemPlace, PackageIdentity } from "@/lib/derive";

export type Page =
  | "home"
  | "library"
  | "marketplaces"
  | "harnesses"
  | "projects"
  | "customize"
  // Reached from one place's card on Projects — adopting is an offer
  // about that place, not a sidebar destination.
  | "unmanaged"
  // Reached from a project's card and from the project's own view — the
  // review of what kendex has written there and not committed. Which
  // project lives in `changesRoot`, so it is never a sidebar destination.
  | "projectChanges"
  | "settings"
  | "updates"
  // Reached from the status footer's problems segment and from every note
  // naming a place with no readable record — never from the sidebar, since
  // it isn't a place you'd navigate to when nothing is wrong.
  | "problems"
  // Reached only by opening a package from a list — which package is open
  // lives in `packageRef`, so the page is never a sidebar destination.
  | "package"
  // Reached only by opening a row on My Library's Templates tab — which
  // template is open lives in `templateName`, so it is no more a sidebar
  // destination than a package page is.
  | "template"
  // Nested under Marketplaces, reached only by opening a row — the open
  // thing lives in its ref, same shape as the package page.
  | "marketplaceDetail"
  | "bundleDetail"
  | "availablePackage";

/** Which of the Marketplaces page's four tabs is showing. */
export type MarketplacesTab = "subscribed" | "packages" | "community" | "mine";

/** Which of My Library's tabs is showing. Installed is the default and
 * keeps the location filter; Templates is the person's across projects and
 * has no place to filter by. Bookmarks joins this list when it exists. */
export type LibraryTab = "installed" | "templates";

/** What a link into the Library is asking to see — every narrowing it wants,
 * where to look included. A link states the whole thing, so a field it leaves
 * out is a narrowing it does not want, and an all-empty filter asks for
 * everything. It is a place plus a kind, which is what lets a kind badge
 * count exactly the rows its own link lands on. */
export interface LibraryFilter extends ItemPlace {
  kind?: ItemKind;
  /** Only packages whose installed files were edited on disk. */
  edited?: boolean;
}

/** The package a package page is showing — everything a backend query
 * needs to address it, plus which of the two things wearing this kind and
 * name the link meant. */
export interface PackageRef {
  kind: ItemKind;
  name: string;
  scope: Scope;
  /** `recorded` for a package the install records account for, `observed`
   * for an installation nothing recorded, which is a different thing under
   * the same label. Stated by every link rather than defaulted: the page
   * holds one of them, and picking for the reader is how one row opens the
   * other's page. A link built from a record is `recorded` by
   * construction. */
  identity: PackageIdentity;
  /** Which file, where the link names a row nothing recorded — its kind
   * and name are not its identity, and another file can wear both. Absent
   * on a recorded link, whose declaration is its identity. */
  at?: string;
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
 * "Preview" on the Updates page lands straight on the diff, and a safety
 * score anywhere lands on the reading behind it. Consumed once by the page
 * on mount, then cleared. */
export type PackageView =
  | { mode: "diff"; from: string; to: string }
  /** Open on the Safety tab. Every safety score in the app is a way to the
   *  findings under it, and they live on that tab. */
  | { mode: "safety" };

/** Where the back button returns to: a page plus its state at push time. */
export interface HistoryEntry {
  page: Page;
  marketplacesTab: MarketplacesTab;
  /** Which My Library tab was showing. Part of where the reader was: Back
   *  out of a template lands on the tab its row was on, not on Installed. */
  libraryTab: LibraryTab;
  /** Which template a template page was showing, by name. */
  templateName: string | null;
  packageRef: PackageRef | null;
  marketplaceRef: MarketplaceRef | null;
  bundleRef: BundleRef | null;
  availableRef: AvailableRef | null;
  unmanagedScope: Scope | null;
  /** The project whose pending changes the review at this entry was of. */
  changesRoot: string | null;
  /** The place the browse at this entry was begun for. Part of where the
   *  reader was, like every ref above it: backing out of a browse begun
   *  for one project must not leave that project selected on the page the
   *  reader lands on, where the next install would take it. */
  installInto: Scope | null;
}
