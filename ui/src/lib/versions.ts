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
 *  and the button above it agree. Both reads have to be in, and nothing
 *  may be withholding the update.
 *
 *  `withheld` is the reason, not a verdict — `update-groups.ts`
 *  [`pageUpdateWithheld`] — and it is passed in rather than derived here
 *  because the page renders it beside this answer. A hidden button with no
 *  note is a page that refuses and never says why, so the two must come
 *  from one reading. */
export const canUpdatePackage = (page: {
  latest: VersionRow | undefined;
  installed: VersionRow | undefined;
  metaLoaded: boolean;
  updatesLoaded: boolean;
  withheld: string | null;
}): boolean =>
  page.latest != null &&
  !page.latest.installed &&
  page.installed != null &&
  page.metaLoaded &&
  page.updatesLoaded &&
  page.withheld === null;
