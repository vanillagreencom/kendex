import { FileWarning, PackageCheck } from "lucide-react";
import { EmptyState } from "@/components/empty-state";
import { PageHeader } from "@/components/page-header";
import { UnmanagedItems } from "@/components/unmanaged-items";
import { unmanagedIn } from "@/lib/audit-counts";
import {
  ALL_MANAGED_BODY,
  ALL_MANAGED_TITLE,
  PLACE_UNCHECKED_TITLE,
  UNMANAGED_SECTION_EXPLAINER,
} from "@/lib/copy";
import { scopeName } from "@/lib/labels";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { sameScope } from "@/lib/scope";
import { cn } from "@/lib/utils";
import { useAuditOnMount, useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";

/**
 * One place's items that kendex didn't put there, and the offer to take
 * them on.
 *
 * Reached from that place's card on Projects, which is the only surface
 * that mentions them at all — nothing is wrong with an unmanaged file, so
 * nothing chases the user about it. Arriving here the list *is* the task,
 * so nothing is folded and every row is ready to act on.
 */
export function UnmanagedPage() {
  useAuditOnMount();
  const scope = useNavStore((s) => s.unmanagedScope);
  const views = useAuditStore((s) => s.views);
  // The audit read's own outcome: a failed adopt is not a failed audit, and
  // says so through the problems dialog rather than this row.
  const auditFailure = useAuditStore((s) => s.read.error);
  const busy = useAuditStore((s) => s.busy);
  const adopt = useAuditStore((s) => s.adopt);

  // No place named is no page: every way in names one, so this is a
  // navigation that never happened rather than a state to design for.
  if (!scope) return null;
  const view = views.find((row) => sameScope(row.scope, scope));
  // Null rows and no rows are different answers: null means the audit could
  // not read this place, so what is at it is unknown. Every button on this
  // page adopts, which writes to the filesystem from the rows it was handed,
  // and those rows are a picture nothing has confirmed.
  const rows = unmanagedIn(view, auditFailure);

  return (
    <div>
      {/* The title names the place, so the subtitle spends its line on
          what the page is for rather than repeating it. */}
      <PageHeader
        title={`Not managed in ${scopeName(scope)}`}
        subtitle={UNMANAGED_SECTION_EXPLAINER}
      />
      <div className={PAGE_BODY}>
        <div className={cn("flex flex-col gap-4", CONTENT_WIDTH)}>
          {rows === null ? (
            <EmptyState icon={FileWarning} title={PLACE_UNCHECKED_TITLE}>
              {view?.error?.message ?? auditFailure}
            </EmptyState>
          ) : rows.length === 0 ? (
            <EmptyState icon={PackageCheck} title={ALL_MANAGED_TITLE}>
              {ALL_MANAGED_BODY}
            </EmptyState>
          ) : (
            <UnmanagedItems
              rows={rows}
              busy={busy}
              onAdopt={(kind, name, harnesses, quiet) =>
                adopt(scope, kind, name, harnesses, quiet)
              }
            />
          )}
        </div>
      </div>
    </div>
  );
}
