import type { UpdateRow } from "@/bindings";

/** One update row for the table tests, every fact defaulted to a plain
 *  following skill with a newer version. */
export const updateRow = (
  name: string,
  root: string | null,
  extra: Partial<UpdateRow> = {},
): UpdateRow => ({
  scope: root ? { scope: "project", root } : { scope: "global" },
  kind: "skill",
  name,
  source: "kendex",
  repo: "vanillagreencom/kendex",
  repoIdentity: "vanillagreencom/kendex",
  current: { commit: "1111111111", label: null, date: null },
  latest: { commit: "2222222222", label: "v2", date: null },
  updateAvailable: true,
  pinned: false,
  blockedByLocalEdit: false,
  editedHarnesses: [],
  forkableHarness: null,
  canDiscard: true,
  canTakeLatest: true,
  holdOwner: null,
  derived: false,
  removedUpstream: false,
  noPerPackageUpdate: null,
  mixed: false,
  forked: false,
  ignored: false,
  ...extra,
});
