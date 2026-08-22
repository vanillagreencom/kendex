import { useState } from "react";
import { SectionHeading } from "@/components/section";
import { Button } from "@/components/ui/button";
import { UnmanagedItems } from "@/components/unmanaged-items";
import {
  HIDE_ITEMS_LABEL,
  showAllItemsLabel,
  UNMANAGED_SECTION_EXPLAINER,
} from "@/lib/copy";
import { mergeDriftRows } from "@/lib/drift-merge";
import { scopeName } from "@/lib/labels";
import { scopeKey } from "@/lib/scope";
import { useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";

// Past this many, the lists fold behind the heading so the Installed table
// they sit above stays the point of the tab.
const INLINE_LIMIT = 5;

/**
 * Items on this machine that kendex was never asked to look after, with the
 * offer to take them on. This lives on the Library's Installed tab because
 * that is where a person looks at what is on the machine; the Review page
 * is for what needs deciding or applying, and adopting is neither — it is
 * an offer, taken up when the person wants it. Follows the app-wide scope
 * like everything else on the tab.
 */
export function NotManagedPanel() {
  const views = useAuditStore((s) => s.views);
  const busy = useAuditStore((s) => s.busy);
  const adopt = useAuditStore((s) => s.adopt);
  const scope = useNavStore((s) => s.libraryScope);
  const [expanded, setExpanded] = useState(false);
  const perScope = views
    .filter((view) => {
      if (scope === "all") return true;
      if (scope === "global") return view.scope.scope === "global";
      return (
        view.scope.scope === "project" && view.scope.root === scope.project
      );
    })
    .map((view) => ({
      view,
      rows: mergeDriftRows(
        view.drift.filter((row) => row.state === "unmanaged"),
      ),
    }))
    .filter(({ rows }) => rows.length > 0);
  const total = perScope.reduce((sum, { rows }) => sum + rows.length, 0);
  if (total === 0) return null;
  const several = perScope.length > 1;
  const among = perScope.map((one) => one.view.scope);
  const foldable = total > INLINE_LIMIT;
  const showLists = !foldable || expanded;
  return (
    <div className="flex flex-col gap-4 pb-8">
      <div className="flex flex-col gap-1">
        <div className="flex items-center justify-between gap-4">
          <SectionHeading>Not managed yet</SectionHeading>
          {foldable ? (
            <Button
              size="sm"
              variant="ghost"
              onClick={() => setExpanded((e) => !e)}
            >
              {expanded ? HIDE_ITEMS_LABEL : showAllItemsLabel(total)}
            </Button>
          ) : null}
        </div>
        <p className="max-w-prose text-[13px] text-muted-foreground">
          {UNMANAGED_SECTION_EXPLAINER}
        </p>
      </div>
      {showLists
        ? perScope.map(({ view, rows }) => (
            <UnmanagedItems
              key={scopeKey(view.scope)}
              rows={rows}
              busy={busy}
              title={several ? scopeName(view.scope, among) : null}
              onAdopt={(kind, name, harness, opts) =>
                adopt(view.scope, kind, name, harness, opts)
              }
            />
          ))
        : null}
    </div>
  );
}
