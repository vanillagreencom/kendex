import {
  type ItemKind,
  PER_PACKAGE_UPDATE_KINDS,
  type VersionRef,
  type VersionRow,
} from "@/bindings";

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

/** Whether the planner can bring one package of this kind current on its
 *  own. The list comes from core, which is also where the refusal behind
 *  it lives, so an offer and its refusal can never come from two accounts
 *  of the same rule. A Pi extension comes current with `kendex update-pi`
 *  and a plugin with its place's own apply. */
export const hasPerPackageUpdate = (kind: ItemKind): boolean =>
  (PER_PACKAGE_UPDATE_KINDS as readonly ItemKind[]).includes(kind);

/** Whether the package page may offer Update. There has to be a newer
 *  version to move to and an installed one to move from, the page has to
 *  know whether the package is held and whether it is edited, no edit may
 *  be holding it — and the planner has to handle the kind at all. Offering
 *  it otherwise is a button that can only fail. */
export const canUpdatePackage = (page: {
  kind: ItemKind;
  latest: VersionRow | undefined;
  installed: VersionRow | undefined;
  metaLoaded: boolean;
  updatesLoaded: boolean;
  edited: boolean;
}): boolean =>
  page.latest != null &&
  !page.latest.installed &&
  page.installed != null &&
  page.metaLoaded &&
  page.updatesLoaded &&
  !page.edited &&
  hasPerPackageUpdate(page.kind);
