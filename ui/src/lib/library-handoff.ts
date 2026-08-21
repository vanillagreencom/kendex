import type { ScopeSelection } from "@/lib/derive";
import type { LibraryFilter } from "@/stores/nav-types";

/** Everything the Library's table is showing: the filter strip, the search
 * box, where it is looking, and where it is scrolled to. */
export interface LibraryView {
  kind: string;
  harness: string;
  tag: string;
  from: string;
  search: string;
  scope: ScopeSelection;
  scrollTop: number;
}

/**
 * The view the Library should adopt for a link that just opened it, or null
 * when it was opened some other way and the stored view stands.
 *
 * A link states the whole view it wants, so everything it does not name goes
 * back to unfiltered rather than carrying over: otherwise "everything in this
 * project" arrives still narrowed to the last kind, tag or search an earlier
 * visit left behind. The table also starts at the top — the offset a previous
 * visit left belongs to a list this one has just replaced.
 */
export function libraryViewFromHandoff(
  handoff: LibraryFilter | null,
): LibraryView | null {
  if (!handoff) return null;
  return {
    kind: handoff.kind ?? "any",
    harness: handoff.harness ?? "any",
    tag: "any",
    from: "any",
    search: "",
    scope: handoff.scope ?? "all",
    scrollTop: 0,
  };
}
