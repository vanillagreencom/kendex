import { PackageCheck } from "lucide-react";
import { EmptyState } from "@/components/empty-state";
import { PageHeader } from "@/components/page-header";
import { UnmanagedItems } from "@/components/unmanaged-items";
import {
  ALL_MANAGED_BODY,
  ALL_MANAGED_TITLE,
  UNMANAGED_PAGE_SUBTITLE,
} from "@/lib/copy";
import { mergeDriftRows } from "@/lib/drift-merge";
import { scopeName } from "@/lib/labels";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useAuditStore } from "@/stores/audit";

/**
 * Everything on this machine kendex didn't put there, on a page of its own.
 *
 * The Library shows the same list above its table, folded, because there it
 * is a footnote to what is installed. Arriving here from Home the list *is*
 * the task, so nothing is folded and every row is ready to act on.
 */
export function UnmanagedPage() {
  const views = useAuditStore((s) => s.views);
  const busy = useAuditStore((s) => s.busy);
  const adopt = useAuditStore((s) => s.adopt);

  const perScope = views
    .map((view) => ({
      view,
      rows: mergeDriftRows(
        view.drift.filter((row) => row.state === "unmanaged"),
      ),
    }))
    .filter(({ rows }) => rows.length > 0);
  const several = perScope.length > 1;

  return (
    <div>
      <PageHeader title="Unmanaged items" subtitle={UNMANAGED_PAGE_SUBTITLE} />
      <div className={PAGE_BODY}>
        <div className={cn("flex flex-col gap-6", CONTENT_WIDTH)}>
          {perScope.length === 0 ? (
            <EmptyState icon={PackageCheck} title={ALL_MANAGED_TITLE}>
              {ALL_MANAGED_BODY}
            </EmptyState>
          ) : (
            perScope.map(({ view, rows }) => (
              <UnmanagedItems
                key={scopeName(view.scope)}
                rows={rows}
                busy={busy}
                title={several ? scopeName(view.scope) : null}
                foldable={false}
                onAdopt={(kind, name, harnesses) =>
                  adopt(view.scope, kind, name, harnesses)
                }
              />
            ))
          )}
        </div>
      </div>
    </div>
  );
}
