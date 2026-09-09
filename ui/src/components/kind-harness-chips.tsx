import type { HarnessId, ItemKind } from "@/bindings";
import { HarnessBadge } from "@/components/harness-badge";
import { openLibraryAt } from "@/components/library/use-filter-handoff";
import { Badge } from "@/components/ui/badge";
import { kindLabel } from "@/lib/labels";

/**
 * What a thing is, and which harnesses load it — the Library's treatment,
 * reused anywhere a row needs to say the same two facts. One grey chip for
 * the kind, then a mark per harness, so the harnesses stay pickable out of a
 * row at a glance instead of hiding inside "Skill · Codex, Pi".
 *
 * The harness chip opens that harness, wherever the row is drawn. What the
 * row itself names may have no page — an unmanaged file, a declaration
 * nothing has installed yet — but the harness always does, and it is the
 * chip that names it.
 */
export function KindHarnessChips({
  kind,
  harnesses,
}: {
  kind: ItemKind;
  harnesses: HarnessId[];
}) {
  return (
    <span className="flex shrink-0 items-center gap-1.5">
      <Badge variant="outline">{kindLabel(kind)}</Badge>
      {harnesses.map((harness) => (
        <HarnessBadge
          key={harness}
          harness={harness}
          compact
          onOpen={() => openLibraryAt({ harness })}
        />
      ))}
    </span>
  );
}
