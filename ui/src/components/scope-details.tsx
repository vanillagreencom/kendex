import { Section } from "@/components/section";
import { Badge } from "@/components/ui/badge";
import { CONFLICT_ZONE_TITLE } from "@/lib/copy-safety";
import { type MergedDriftRow, mergedDetail } from "@/lib/drift-merge";
import {
  driftDetail,
  harnessName,
  kindLabel,
  STATE_BADGES,
  STATE_LABELS,
} from "@/lib/labels";

/** What needs a person rather than an apply: a conflict has no ops behind
 *  it, so the Apply button cannot clear it and listing it as ready to apply
 *  promises an action that is not there. Each row opens the package at the
 *  place it is about, which is where its exits live. */
export function ScopeConflicts({
  conflicts,
  onOpen,
}: {
  conflicts: MergedDriftRow[];
  onOpen: (row: MergedDriftRow) => void;
}) {
  if (conflicts.length === 0) return null;
  return (
    <Section title={CONFLICT_ZONE_TITLE}>
      <div className="divide-y divide-border">
        {conflicts.map((group) => (
          <div
            key={`${group.kind}:${group.name}`}
            className="flex flex-wrap items-center gap-2 py-2.5 first:pt-0 last:pb-0"
          >
            {/* Only a package has a page to open. A file kendex writes
                beside them would navigate to something the scan cannot
                contain, and the page would bounce straight back. */}
            {group.subject === "package" ? (
              <button
                type="button"
                className="text-sm font-medium underline underline-offset-2 hover:text-foreground"
                onClick={() => onOpen(group)}
              >
                {group.name}
              </button>
            ) : (
              <span className="text-sm font-medium">{group.name}</span>
            )}
            <span className="text-xs text-muted-foreground">
              {kindLabel(group.kind)}
            </span>
            <span className="text-xs text-muted-foreground">
              {mergedDetail(group.installations.map(driftDetail))}
            </span>
          </div>
        ))}
      </div>
    </Section>
  );
}

/** What applying this project would do, one line per thing it touches. */
export function ScopeChanges({ changes }: { changes: MergedDriftRow[] }) {
  if (changes.length === 0) return null;
  return (
    <Section title="Ready to apply">
      <div className="divide-y divide-border">
        {changes.map((group) => {
          const detail = mergedDetail(group.installations.map(driftDetail));
          const tools = group.installations
            .map((row) => harnessName(row.harness))
            .join(", ");
          return (
            <div
              key={`${group.kind}:${group.name}:${group.state}`}
              className="flex flex-wrap items-center gap-2 py-2.5 first:pt-0 last:pb-0"
            >
              <span className="text-sm font-medium">{group.name}</span>
              <Badge variant={STATE_BADGES[group.state]}>
                {STATE_LABELS[group.state]}
              </Badge>
              <span className="text-xs text-muted-foreground">
                {kindLabel(group.kind)} · {tools}
              </span>
              {detail ? (
                <span className="text-xs text-muted-foreground">{detail}</span>
              ) : null}
            </div>
          );
        })}
      </div>
    </Section>
  );
}
