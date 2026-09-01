import type { DriftRow, HarnessId } from "@/bindings";
import type { MergedDriftRow } from "@/lib/drift-merge";
import { harnessName } from "@/lib/labels";
import { sameScope } from "@/lib/scope";
import { useScanStore } from "@/stores/scan";

export interface SharedLink {
  group: MergedDriftRow;
  /** The harness whose link to adopt through — the core resolves the
   *  target and takes every sibling link with it in one plan. */
  harness: HarnessId;
  /** The real folder the links resolve to. */
  target: string;
  /** Every harness whose install is a link at that folder. */
  tools: string[];
}

// An install that is a live symlink adopts the *target* — a folder the
// user may have pointed several harnesses at. That is a bigger move than
// adopting a plain folder (the old folder is trashed, and links kendex
// cannot see will break), so it gets a confirmation naming the folder and
// every harness reading it. Detection reads the scan, which resolves links.
export function sharedLinkOf(group: MergedDriftRow): SharedLink | null {
  const items = useScanStore.getState().result?.items ?? [];
  for (const row of group.installations) {
    const item = items.find(
      (it) =>
        it.kind === group.kind &&
        it.name === group.name &&
        it.harness === row.harness &&
        sameScope(it.scope, row.scope),
    );
    if (item?.fileState.state !== "symlink" || item.fileState.broken) {
      continue;
    }
    const target = item.fileState.target;
    const tools = items
      .filter(
        (it) =>
          it.kind === group.kind &&
          it.name === group.name &&
          sameScope(it.scope, row.scope) &&
          it.fileState.state === "symlink" &&
          !it.fileState.broken &&
          it.fileState.target === target,
      )
      .map((it) => harnessName(it.harness));
    return {
      group,
      harness: row.harness,
      target,
      tools: [...new Set(tools)],
    };
  }
  return null;
}

/** Start managing a page of items, in the order they are read. */
type Adopt = (
  kind: DriftRow["kind"],
  name: string,
  harnesses: DriftRow["harness"][],
  quiet?: boolean,
) => Promise<boolean>;

/**
 * One item at a time: every apply takes the scope's writer lock, so firing
 * them together turns all but the first into "scope is busy". The first
 * failure stops the rest — after one has failed the others are answering
 * against a page that is now wrong, and the run would still finish looking
 * like it worked. An item's tools go in one call, since taken one at a
 * time each tool's copy lands in the local source on top of the last and
 * the declaration keeps only the first.
 *
 * The run says one line, not one per item: a page of them is one action to
 * the person who clicked it.
 *
 * A folder shared through shortcuts needs its own confirmation, so the
 * first one found is handed back rather than adopted here.
 */
export async function adoptAll(
  groups: MergedDriftRow[],
  linkOf: (group: MergedDriftRow) => SharedLink | null,
  adopt: Adopt,
): Promise<SharedLink | null> {
  let shared: SharedLink | null = null;
  let said = false;
  for (const group of groups) {
    const link = linkOf(group);
    if (link) {
      shared ??= link;
      continue;
    }
    const harnesses = [
      ...new Set(group.installations.map((row) => row.harness)),
    ];
    // Nothing carries past a failure, the deferred folder included: its
    // confirmation would open against a page that is now wrong.
    if (!(await adopt(group.kind, group.name, harnesses, said))) return null;
    said = true;
  }
  return shared;
}
