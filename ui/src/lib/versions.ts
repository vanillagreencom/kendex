import type { VersionRef, VersionRow } from "@/bindings";

/** A version as a person reads it: the release name when it has one, a
 *  short commit id otherwise. */
export function versionLabel(
  version: Pick<VersionRef, "commit" | "label">,
): string {
  return version.label ?? version.commit.slice(0, 7);
}

export function versionRowLabel(row: VersionRow): string {
  return row.label ?? row.id.slice(0, 7);
}

/** The row a fresh "Update" should land on: the newest one. */
export function latestRow(rows: VersionRow[]): VersionRow | undefined {
  return rows[0];
}

export function installedRow(rows: VersionRow[]): VersionRow | undefined {
  return rows.find((row) => row.installed);
}

/** A newer version to move to: what the read-only comparison needs, and what
 *  a note about not being able to take it has to explain. */
export const hasNewer = (latest: VersionRow | undefined): boolean =>
  latest != null && !latest.installed;

/** Whether the package page may offer Update. Newness is the page's own:
 *  it reads a newer version to move to and an installed one to move from
 *  off its version rows, not off the update row, so the timeline it draws
 *  and the button above it agree.
 *
 *  `withheld` is the reason, not a verdict, and [`updateOffer`] below is
 *  where the two reads behind the page are ranked into it. Every gate past
 *  the ones here reaches this through that one string, which is the rule and
 *  not a habit of the caller: a reason that cannot be said cannot hide the
 *  button, and a page that refuses without saying why is the shape that
 *  costs. So this asks only what the page itself knows — a version to move
 *  to and from, and the meta read that says held or following — and defers
 *  the rest. */
export const canUpdatePackage = (page: {
  latest: VersionRow | undefined;
  installed: VersionRow | undefined;
  metaLoaded: boolean;
  withheld: string | null;
}): boolean =>
  hasNewer(page.latest) &&
  page.installed != null &&
  page.metaLoaded &&
  page.withheld === null;

/** What the package page's header offers, and what it says instead. */
export interface UpdateOffer {
  /** Whether Update is offered. */
  can: boolean;
  /** Why there is none, where a reason has to be said. */
  note: string | null;
  /** Whether reading the package again can lift that reason. */
  retry: boolean;
}

/** The header's whole answer about Update, ranked once so the button and the
 *  note beside it can never disagree.
 *
 *  Four reasons, ranked by what each is a fact about, because no order over
 *  the words themselves can be right.
 *
 *  A source no fetch has downloaded yet comes first (`package-read-state.ts`
 *  [`unfetchedNote`]). It is why everything after it has nothing to say:
 *  the update check records the same case as a warning and leaves no row
 *  (`crates/core/src/package/updates/eval.rs`), so the fact the check would
 *  otherwise state here is that it never covered this place, which is the
 *  symptom of this cause. Nothing this page can re-read lifts it, so it
 *  carries no [`retry`]; the note names the source to refresh instead. It
 *  speaks ahead of this page's own reads on purpose: the record read fails
 *  on the same unfetched source, in core's words (`crates/core/src/package/
 *  detail.rs` `package_meta`), and a record read that failed for a reason
 *  of its own — a lock this build cannot read — gets its words and its
 *  retry once the source is fetched, which had to happen first anyway.
 *
 *  Then a fact about the package (`updates-read-state.ts`
 *  [`packageUpdateNote`]): core's refusal for the kind, a hold, an edit of
 *  the reader's own, a place a settled check never covered. Those are
 *  answers — true whatever any read does next.
 *
 *  Then this page's own reads (`package-read-state.ts` [`packageReadNote`]).
 *  Two of core's answers never arrive here as errors: nothing declared under
 *  this name, and a source with no repository. The command layer folds both
 *  into an absent value (`crates/app/src/packages.rs` `no_managed_package`),
 *  and the unfetched source arrives as its own shape (`TimelineRefused`),
 *  so the page never tells an answer about the manifest apart from a read
 *  that failed, and [`retry`] offers a read of this package again rather
 *  than a button over something no read can change.
 *
 *  The update read's own standing comes last (`updates-read-state.ts`
 *  [`updatesReadNote`]): a check still running or one that failed says
 *  nothing about this package, and letting it speak first would leave a real
 *  failure of this page's reads unsaid in exactly the correlated case — the
 *  transport being down takes the standing out too. It is silent where a
 *  landed row already covers the place, which is that function's own rule:
 *  the page keeps its version-changing controls on screen through a check
 *  rather than swapping them for a note.
 *
 *  `installed` and `latest` gate all of it: only a timeline showing the
 *  installed version already at its newest is nothing to explain. No
 *  timeline at all is not that — a kind core refuses, a fork, a read that
 *  did not land — and a page silent there is an action bar with nothing on
 *  it and nothing beside it. */
export const updateOffer = (page: {
  latest: VersionRow | undefined;
  installed: VersionRow | undefined;
  metaLoaded: boolean;
  /** The source this package's timeline waits on a fetch of, or null. */
  unfetched: string | null;
  /** What the update read says about this package, or null. */
  withheld: string | null;
  /** Why this page's own reads say there is no Update, or null. */
  readNote: string | null;
  /** How the update read itself is standing, or null. */
  standing: string | null;
}): UpdateOffer => {
  const reason =
    page.unfetched ?? page.withheld ?? page.readNote ?? page.standing;
  // The button and the note come from the one string, so whatever withholds
  // an Update is also what is said in its place.
  const current = page.installed != null && !hasNewer(page.latest);
  return {
    can: canUpdatePackage({ ...page, withheld: reason }),
    note: current ? null : reason,
    retry:
      !current &&
      page.unfetched === null &&
      page.withheld === null &&
      page.readNote !== null,
  };
};
