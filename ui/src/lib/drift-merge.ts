// A declared item fans out to one DriftRow per harness it targets — a
// skill adopted for both Claude Code and Pi is one thing to a person, so
// the review card folds those rows back together before rendering.
import type { DriftRow, ItemSafety } from "@/bindings";

export interface MergedDriftRow {
  kind: DriftRow["kind"];
  name: string;
  state: DriftRow["state"];
  /** What the row is about, which decides whether it has a page to open.
   *  Merged rows share it: the key includes it, so a group is never a mix. */
  subject: DriftRow["subject"];
  installations: DriftRow[];
}

export function mergeDriftRows(rows: DriftRow[]): MergedDriftRow[] {
  const groups = new Map<string, MergedDriftRow>();
  for (const row of rows) {
    const key = `${row.kind}:${row.name}:${row.state}:${row.subject}`;
    let group = groups.get(key);
    if (!group) {
      group = {
        kind: row.kind,
        name: row.name,
        state: row.state,
        subject: row.subject,
        installations: [],
      };
      groups.set(key, group);
    }
    group.installations.push(row);
  }
  return [...groups.values()];
}

// The detail text a merged row shows: the same message repeated per
// harness collapses to one, but genuinely different messages per harness
// stay distinct instead of one hiding the other.
export function mergedDetail(details: (string | null)[]): string | null {
  const unique = [...new Set(details.filter((d): d is string => !!d))];
  return unique.length === 0 ? null : unique.join(" · ");
}

// A path under the user's home directory, shortened the way a person
// would say it out loud rather than type it.
export function abbreviateHome(path: string): string {
  return path.replace(/^\/(?:home|Users)\/[^/]+/, "~");
}

export interface PathSummary {
  text: string;
  title: string;
}

// Two paths read fine side by side; three or more turn a row into a wall
// of mono text, so those collapse to the first path plus a count. The
// title attribute always carries every path in full, so nothing is lost.
export function summarizePaths(paths: (string | null)[]): PathSummary | null {
  const present = paths.filter((p): p is string => !!p);
  if (present.length === 0) return null;
  const title = present.join("\n");
  if (present.length <= 2) {
    return { text: present.map(abbreviateHome).join(" · "), title };
  }
  return {
    text: `${abbreviateHome(present[0])} +${present.length - 1} more`,
    title,
  };
}

/** The conflicts whose exit really is on the package's own page.
 *
 *  A safety refusal is a conflict too: the gate held the install back and
 *  the previous rendering came off disk with it. Its exit is the accept or
 *  dismiss decision already on offer above, and no package page can settle
 *  a safety decision — so listing it here shows one thing twice and points
 *  the second copy at a page that cannot help. The refusals are exactly the
 *  items the same view reports as held back, harness by harness. */
export function packageConflicts(
  drift: DriftRow[],
  heldBack: ItemSafety[],
): DriftRow[] {
  const key = (row: { kind: string; name: string; harness: string }) =>
    `${row.kind}:${row.name}:${row.harness}`;
  const refused = new Set(heldBack.map(key));
  return drift.filter(
    (row) => row.state === "conflict" && !refused.has(key(row)),
  );
}

/** Review's two lists. An apply runs a plan, and a conflict has no ops
 *  behind it — filing one under "ready to apply" counts it as work a button
 *  can do and then offers no button. Its exits live on the package's own
 *  page, so it is listed apart, with the way there. Unmanaged items are
 *  neither: they are a footnote pointing at the Library. */
export function reviewLists(
  drift: DriftRow[],
  heldBack: ItemSafety[],
): {
  changes: MergedDriftRow[];
  conflicts: MergedDriftRow[];
} {
  return {
    changes: mergeDriftRows(
      drift.filter(
        (row) => row.state !== "unmanaged" && row.state !== "conflict",
      ),
    ),
    conflicts: mergeDriftRows(packageConflicts(drift, heldBack)),
  };
}
