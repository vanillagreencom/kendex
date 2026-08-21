import { ChevronDown, ChevronRight } from "lucide-react";
import { useState } from "react";
import type { AuditView, DismissReason } from "@/bindings";
import { ApplyDialog } from "@/components/apply-dialog";
import { BlockedDeclarations } from "@/components/blocked-declarations";
import { SafetyWarnings } from "@/components/safety-findings-affected";
import { BlockedFindings } from "@/components/safety-findings-blocked";
import { ScopeChanges } from "@/components/scope-details";
import { ScopeFooter } from "@/components/scope-footer";
import { Section } from "@/components/section";
import { Button } from "@/components/ui/button";
import { blockedCount as countBlocked } from "@/lib/audit-counts";
import {
  APPLY_BUTTON_LABEL,
  NOTHING_TO_DO_HERE,
  scopeSummaryLabel,
} from "@/lib/copy";
import { DECISION_ZONE_TITLE } from "@/lib/copy-safety";
import { driftZones } from "@/lib/drift-zones";
import { partitionSafety } from "@/lib/group-findings";
import { scopeName, scopePath } from "@/lib/labels";
import { evidenceGroups, openOccurrences } from "@/lib/reviewable";

/**
 * One project (or Personal), as its own panel.
 *
 * A machine with six projects used to be six full pages stacked end to end
 * with nothing but whitespace between them. Each is a container of its own
 * now, headed by what it needs and the button that does it, and a project
 * with nothing urgent starts closed — the header still says what's inside,
 * so nothing is hidden, it just isn't all shouting at once.
 */
export function SyncScopeCard({
  view,
  busy,
  onApply,
  onDismiss,
  onKeepFiles,
  onReplaceFiles,
  onSeeUnmanaged,
}: {
  view: AuditView;
  busy: boolean;
  onApply: (removeOrphans: boolean, allowUnsafe?: string[]) => void;
  onDismiss: (tokens: string[], reason: DismissReason) => void;
  /** Hand the files already at an item's place to kendex as they are, for
   *  every tool the item is blocked for. */
  onKeepFiles: (
    kind: AuditView["drift"][number]["kind"],
    name: string,
    harnesses: AuditView["drift"][number]["harness"][],
  ) => Promise<unknown>;
  /** Install what kendex.toml asks for over them instead. */
  onReplaceFiles: (
    kind: AuditView["drift"][number]["kind"],
    name: string,
  ) => Promise<unknown>;
  /** Opens the Library's Installed tab on this scope, where adopting lives. */
  onSeeUnmanaged: () => void;
}) {
  const [applyOpen, setApplyOpen] = useState(false);
  const { inTheWay, changes, unmanaged, orphans } = driftZones(view.drift);
  const {
    blocked,
    open: undecided,
    settled,
    clean,
  } = partitionSafety(view.safety);
  // The same numbers the sidebar and Home read, so the card can never say
  // one thing and the badge another.
  const blockedCount = countBlocked(view);
  const openCount = evidenceGroups(openOccurrences(undecided)).length;
  // With nothing else to fix, removing left-behind items is the only
  // change on offer — defaulting the checkbox on keeps it reachable.
  const orphansOnly = orphans.length > 0 && view.plan.length === 0;
  const [removeOrphans, setRemoveOrphans] = useState(orphansOnly);
  const canApply = view.plan.length > 0 || orphans.length > 0;
  const summary = scopeSummaryLabel({
    changes: changes.length,
    decide: inTheWay.length,
    blocked: blockedCount,
    open: openCount,
    unmanaged: unmanaged.length,
  });
  const [open, setOpen] = useState(
    blockedCount > 0 || openCount > 0 || inTheWay.length > 0 || canApply,
  );
  const path = scopePath(view.scope);

  return (
    <section className="overflow-hidden rounded-xl border bg-card">
      <div className="flex items-center gap-3 px-4 py-3">
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          className="flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 text-left"
        >
          {open ? (
            <ChevronDown className="size-4 shrink-0 text-muted-foreground" />
          ) : (
            <ChevronRight className="size-4 shrink-0 text-muted-foreground" />
          )}
          <span className="flex min-w-0 flex-col">
            <span className="truncate text-[15px] font-semibold tracking-tight">
              {scopeName(view.scope)}
            </span>
            <span className="truncate text-[13px] text-muted-foreground">
              {summary ?? NOTHING_TO_DO_HERE}
            </span>
          </span>
        </button>
        {path ? (
          <span className="hidden max-w-[40%] min-w-0 shrink truncate font-mono text-xs text-muted-foreground lg:block">
            {path}
          </span>
        ) : null}
        {canApply ? (
          <Button
            size="sm"
            className="shrink-0"
            disabled={busy}
            onClick={() => {
              if (orphansOnly) setRemoveOrphans(true);
              setApplyOpen(true);
            }}
          >
            {APPLY_BUTTON_LABEL}
          </Button>
        ) : null}
      </div>
      {/* Two zones, in the order a person works them. Needs your decision
          holds everything only they can settle: installs the gate is holding
          back, then findings nobody has ruled on. Ready to apply is what the
          button does. Notes and the safety tally follow; items kendex does
          not manage are a footnote pointing at the Library, where adopting
          them lives. */}
      {open ? (
        <div className="flex flex-col gap-6 border-t px-4 py-4">
          {blockedCount > 0 || openCount > 0 || inTheWay.length > 0 ? (
            <Section title={DECISION_ZONE_TITLE}>
              <div className="flex flex-col gap-3">
                <BlockedDeclarations
                  rows={inTheWay}
                  adoptable={view.adoptable}
                  alsoApplies={view.plan.length > 0}
                  busy={busy}
                  onKeep={onKeepFiles}
                  onReplace={onReplaceFiles}
                />
                <BlockedFindings
                  rows={blocked}
                  heldBack={view.heldBack}
                  busy={busy}
                  projectScope={view.scope.scope === "project"}
                  onAccept={(tokens) => onApply(false, tokens)}
                />
                <SafetyWarnings
                  rows={undecided}
                  projectScope={view.scope.scope === "project"}
                  busy={busy}
                  onDismiss={onDismiss}
                />
              </div>
            </Section>
          ) : null}
          <ScopeChanges changes={changes} />
          <ScopeFooter
            clean={clean}
            settled={settled}
            alsoScored={[...undecided, ...blocked]}
            notes={view.notes}
            warnings={view.warnings}
            unmanaged={unmanaged.length}
            onSeeUnmanaged={onSeeUnmanaged}
          />
        </div>
      ) : null}
      <ApplyDialog
        open={applyOpen}
        onOpenChange={setApplyOpen}
        view={view}
        orphans={orphans}
        busy={busy}
        removeOrphans={removeOrphans}
        onRemoveOrphansChange={setRemoveOrphans}
        onApply={() => {
          onApply(removeOrphans);
          setApplyOpen(false);
        }}
      />
    </section>
  );
}
