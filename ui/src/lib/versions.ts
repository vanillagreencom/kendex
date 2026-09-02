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
  page.latest != null &&
  !page.latest.installed &&
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
 *  The update read answers first, on the terms it always had: core's refusal
 *  for the kind, a hold, an edit of the reader's own, a place no check
 *  covered (`updates-read-state.ts` [`packageUpdateNote`]). The page's own
 *  reads speak only into its silence (`package-read-state.ts`
 *  [`packageReadNote`]), which is a row that exists with nothing withholding
 *  it — a declared package from a repository source whose kind plans one at
 *  a time. That is the one state none of the permanent refusals core answers
 *  a page read with can reach, so a note from there is a read that went
 *  wrong rather than one of those worded as a failure.
 *
 *  `timelineUnread` is why the rank alone is not enough: with no timeline
 *  there is no newer version, and a reason held behind newness would go
 *  unsaid exactly where the page knows least. Only a timeline that landed
 *  may say there is nothing to move to.
 *
 *  Retry answers the page's own reads and nothing else: every reason the
 *  update read carries is answered by a check or by the package's own state,
 *  and a button there would ask for a read that changes nothing. */
export const updateOffer = (page: {
  latest: VersionRow | undefined;
  installed: VersionRow | undefined;
  metaLoaded: boolean;
  /** Why the update read withholds one, or null when it does not. */
  withheld: string | null;
  /** Why the page's own reads withhold one, or null when they do not. */
  readNote: string | null;
  /** Whether the page's own timeline read did not land. */
  timelineUnread: boolean;
}): UpdateOffer => {
  const reason = page.withheld ?? page.readNote;
  const said = hasNewer(page.latest) || page.timelineUnread ? reason : null;
  return {
    can: canUpdatePackage({ ...page, withheld: reason }),
    note: said,
    retry: said !== null && page.withheld === null,
  };
};
