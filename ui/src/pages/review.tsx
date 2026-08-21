import { CheckCircle2 } from "lucide-react";
import { useEffect } from "react";
import { EmptyState } from "@/components/empty-state";
import { DotSpinner } from "@/components/loading";
import { PageHeader } from "@/components/page-header";
import { ScopeErrorCard } from "@/components/scope-error-card";
import { StatusNote } from "@/components/status-note";
import { SyncScopeCard } from "@/components/sync-scope";
import { blockedCount, openCount } from "@/lib/audit-counts";
import { ALL_IN_SYNC_BODY, ALL_IN_SYNC_TITLE } from "@/lib/copy";
import { scopeLabel } from "@/lib/derive";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";

export function ReviewPage() {
  const {
    views,
    auditing,
    error,
    busy,
    refresh,
    applyPlan,
    dismiss,
    adopt,
    replaceUnmanaged,
  } = useAuditStore();
  const goTo = useNavStore((s) => s.goTo);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // A scope is finished when nothing in it waits on a person: no change to
  // apply, no note, and no decision left to make. Findings someone already
  // ruled on do not keep the page open — that is what ruling on them is for.
  const active = views.filter(
    (view) =>
      view.error != null ||
      view.drift.length > 0 ||
      view.notes.length > 0 ||
      view.warnings.length > 0 ||
      blockedCount(view) > 0 ||
      openCount(view) > 0,
  );
  const allClean = !auditing && active.length === 0;

  return (
    <div>
      <PageHeader title="Review & apply" />
      <div className={PAGE_BODY}>
        <div className={cn("flex flex-col gap-12", CONTENT_WIDTH)}>
          {error ? (
            <StatusNote tone="critical" title="Checking for changes failed">
              {error}
            </StatusNote>
          ) : null}
          {auditing && views.length === 0 ? (
            <p className="flex items-center gap-2 text-sm text-muted-foreground">
              <DotSpinner />
              Checking for changes…
            </p>
          ) : null}
          {allClean ? (
            <EmptyState icon={CheckCircle2} title={ALL_IN_SYNC_TITLE}>
              {ALL_IN_SYNC_BODY}
            </EmptyState>
          ) : (
            active.map((view) =>
              view.error ? (
                <ScopeErrorCard
                  key={scopeLabel(view.scope)}
                  view={view}
                  error={view.error}
                />
              ) : (
                <SyncScopeCard
                  key={scopeLabel(view.scope)}
                  view={view}
                  busy={busy}
                  onApply={(removeOrphans, allowUnsafe) =>
                    void applyPlan(view.scope, removeOrphans, allowUnsafe)
                  }
                  onDismiss={(tokens, reason) =>
                    void dismiss(view.scope, tokens, reason)
                  }
                  onKeepFiles={(kind, name, harnesses) =>
                    adopt(view.scope, kind, name, harnesses)
                  }
                  onReplaceFiles={(kind, name) =>
                    replaceUnmanaged(view.scope, kind, name)
                  }
                  onSeeUnmanaged={() => goTo("unmanaged")}
                />
              ),
            )
          )}
        </div>
      </div>
    </div>
  );
}
