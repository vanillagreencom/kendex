// A declared item fans out to one DriftRow per harness it targets — a
// skill adopted for both Claude Code and Pi is one thing to a person, so
// the review card folds those rows back together before rendering.
import type { DriftRow } from "@/bindings";

export interface MergedDriftRow {
  kind: DriftRow["kind"];
  name: string;
  state: DriftRow["state"];
  installations: DriftRow[];
}

export function mergeDriftRows(rows: DriftRow[]): MergedDriftRow[] {
  const groups = new Map<string, MergedDriftRow>();
  for (const row of rows) {
    const key = `${row.kind}:${row.name}:${row.state}`;
    let group = groups.get(key);
    if (!group) {
      group = {
        kind: row.kind,
        name: row.name,
        state: row.state,
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
  /** How many distinct places this row is about — several tools reading
   *  one folder is one place, and a sentence that counted it twice would
   *  be wrong about what moves. */
  count: number;
}

// Two paths read fine side by side; three or more turn a row into a wall
// of mono text, so those collapse to the first path plus a count. The
// title attribute always carries every path in full, so nothing is lost.
export function summarizePaths(paths: (string | null)[]): PathSummary | null {
  const present = [...new Set(paths.filter((p): p is string => !!p))];
  if (present.length === 0) return null;
  const title = present.join("\n");
  const count = present.length;
  if (count <= 2) {
    return { text: present.map(abbreviateHome).join(" · "), title, count };
  }
  return {
    text: `${abbreviateHome(present[0])} +${count - 1} more`,
    title,
    count,
  };
}
