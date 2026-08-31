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

/** Whether the package page may offer Update. Newness is the page's own:
 *  it reads a newer version to move to and an installed one to move from
 *  off its version rows, not off the update row, so the timeline it draws
 *  and the button above it agree.
 *
 *  `withheld` is the reason, not a verdict — `update-groups.ts`
 *  [`pageUpdateWithheld`] — and it is the whole of the update read's say
 *  here. There is deliberately no second gate on how that read went: a
 *  reason that cannot be said cannot hide the button, and a page that
 *  refuses without saying why is the shape that costs. So this asks only
 *  what the page itself knows — a version to move to and from, and the
 *  meta read that says held or following — and defers the rest. */
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
