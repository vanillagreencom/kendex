import { ChevronDown, ChevronRight } from "lucide-react";
import { useState } from "react";
import type { ItemSafety } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { KindHarnessChips } from "@/components/kind-harness-chips";
import { FindingLine } from "@/components/safety-findings";
import { StatusDot } from "@/components/status-dot";
import { Button } from "@/components/ui/button";
import {
  ACCEPT_BLOCKED_CONFIRM,
  ACCEPT_BLOCKED_LABEL,
  ACCEPT_BLOCKED_TITLE,
  acceptBlockedBody,
  BLOCKED_SECTION_EXPLAINER,
  HELD_BACK_NOT_ON_DISK_NOTE,
  NOTHING_TO_ACCEPT,
  publisherSettledNote,
} from "@/lib/copy-safety";
import { findingHeadline } from "@/lib/finding-headlines";
import {
  acceptTokens,
  type BlockedGroup,
  groupBlocked,
  leadRuleGroup,
  mergeHeldBack,
  ruleGroupAsFinding,
} from "@/lib/group-findings-blocked";
import { harnessName, hookDisplayName, moreItemsLabel } from "@/lib/labels";

// A row where every rule was skipped has not been audited, and showing
// nothing would read as an audit that passed. It gets a line of its own
// saying what could not be looked at. Prefixed with the harness name once a
// blocked entry spans more than one, so a note about Codex isn't read as
// also true of Pi.
function BlockedRowNotes({
  row,
  harnessPrefix,
  onDisk,
}: {
  row: ItemSafety;
  harnessPrefix: string;
  onDisk: boolean;
}) {
  return (
    <>
      {!onDisk ? (
        <p className="text-xs text-foreground/70">
          {harnessPrefix}
          {HELD_BACK_NOT_ON_DISK_NOTE}
        </p>
      ) : null}
      {row.override.state === "stale" ? (
        <p className="text-xs text-foreground/70">
          {harnessPrefix}This was accepted before, but {row.override.why}.
        </p>
      ) : null}
      {row.override.state === "active" ? (
        <p className="text-xs text-foreground/70">
          {harnessPrefix}These findings were read and accepted, so this stays
          installed.
        </p>
      ) : null}
      {row.skipped.length > 0 ? (
        <p className="text-xs text-foreground/70">
          {harnessPrefix}Not fully checked here: {row.skipped.length} rule
          {row.skipped.length === 1 ? "" : "s"} had nothing to read —{" "}
          {row.skipped[0].reason}
        </p>
      ) : null}
    </>
  );
}

// One disclosure row per grouped held-back entry — same anatomy as
// FindingRow in safety-findings-affected.tsx: a dot, a headline, a scope
// chip, a chevron. Held back is always the loudest verdict there is, so the
// dot stays critical regardless of whether a row inside was later accepted;
// that nuance is said in prose once the row opens, not in the dot's color.
function BlockedGroupRow({
  group,
  planned,
  onDisk,
  busy,
  projectScope,
  onAccept,
}: {
  group: BlockedGroup;
  /** Plan-time held-back rows for this item; empty when the next apply
   *  would not write it (an unmanaged item — accepting can do nothing). */
  planned: ItemSafety[];
  onDisk: Set<string>;
  busy: boolean;
  projectScope: boolean;
  onAccept: (tokens: string[]) => void;
}) {
  const [open, setOpen] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const lead = leadRuleGroup(group.findingGroups);
  const extraCount = group.findingGroups.length - 1;
  const name = group.kind === "hook" ? hookDisplayName(group.name) : group.name;
  const harnesses = [...new Set(group.rows.map((row) => row.harness))];
  // Only rows the gate has not already cleared want accepting — a group
  // can hold an accepted (active) row beside a still-blocked sibling.
  const tokens = acceptTokens(
    planned.filter((row) => row.override.state !== "active"),
  );

  return (
    <div>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className="flex w-full cursor-pointer items-center gap-2.5 px-3 py-2.5 text-left hover:bg-critical/5"
      >
        <StatusDot tone="critical" />
        <span className="min-w-0 flex-1 truncate text-sm font-medium">
          {name} — {findingHeadline(lead.rule, lead.message)}
          {extraCount > 0 ? (
            <span className="font-normal text-muted-foreground">
              {" "}
              {moreItemsLabel(extraCount)}
            </span>
          ) : null}
        </span>
        <KindHarnessChips kind={group.kind} harnesses={harnesses} />
        {open ? (
          <ChevronDown className="size-4 shrink-0 text-muted-foreground" />
        ) : (
          <ChevronRight className="size-4 shrink-0 text-muted-foreground" />
        )}
      </button>
      {open ? (
        <div className="flex flex-col gap-3 border-t border-critical/15 bg-critical/5 px-3 py-3.5">
          {group.rows.map((row) => (
            <BlockedRowNotes
              key={row.harness}
              row={row}
              onDisk={onDisk.has(`${row.kind}::${row.name}::${row.harness}`)}
              harnessPrefix={
                harnesses.length > 1 ? `${harnessName(row.harness)}: ` : ""
              }
            />
          ))}
          {/* A held-back item can carry findings its publisher already
              settled beside the ones holding it back. The score beside it
              already excludes those, so the line has to say whose call it
              was rather than print a fix nobody is counting. */}
          {group.findingGroups.map((ruleGroup) => (
            <FindingLine
              key={`${ruleGroup.rule}:${ruleGroup.message}`}
              finding={ruleGroupAsFinding(ruleGroup)}
              locations={ruleGroup.locations}
              settledBy={
                ruleGroup.settledBy
                  ? publisherSettledNote(
                      ruleGroup.settledBy.publisher,
                      ruleGroup.settledBy.reason,
                      null,
                    )
                  : undefined
              }
            />
          ))}
          {tokens.length > 0 ? (
            <div>
              <Button
                size="sm"
                disabled={busy}
                onClick={() => setConfirming(true)}
              >
                {ACCEPT_BLOCKED_LABEL}
              </Button>
            </div>
          ) : (
            <p className="text-[13px] text-foreground/70">
              {NOTHING_TO_ACCEPT}
            </p>
          )}
        </div>
      ) : null}
      <ConfirmDialog
        open={confirming}
        onOpenChange={setConfirming}
        title={ACCEPT_BLOCKED_TITLE}
        description={acceptBlockedBody(projectScope)}
        confirmLabel={ACCEPT_BLOCKED_CONFIRM}
        busy={busy}
        onConfirm={() => {
          onAccept(tokens);
          setConfirming(false);
        }}
      />
    </div>
  );
}

// Held back items stop an install outright; the tinted panel keeps them the
// loudest thing on the card no matter what else is going on. Rows sharing a
// skill's files across harnesses, or a rule repeating across locations, are
// merged before rendering — see groupBlocked in group-findings-blocked.ts.
// `rows` is what is on disk; `heldBack` is what the plan refuses to write —
// the union renders, and the accept action exists exactly where a plan-time
// row carries the hash the gate checks.
export function BlockedFindings({
  rows,
  heldBack,
  busy,
  projectScope,
  onAccept,
}: {
  rows: ItemSafety[];
  heldBack: ItemSafety[];
  busy: boolean;
  projectScope: boolean;
  onAccept: (tokens: string[]) => void;
}) {
  const { display, plannedByItem, onDisk } = mergeHeldBack(rows, heldBack);
  const groups = groupBlocked(display);
  if (groups.length === 0) return null;
  return (
    <div className="overflow-hidden rounded-lg border border-critical/30">
      <p className="border-b border-critical/20 bg-critical/5 px-3 py-2 text-[13px] text-foreground/75">
        {BLOCKED_SECTION_EXPLAINER}
      </p>
      <div className="divide-y divide-critical/15">
        {groups.map((group) => (
          <BlockedGroupRow
            key={group.rows
              .map((row) => `${row.kind}:${row.name}:${row.harness}`)
              .join("|")}
            group={group}
            planned={plannedByItem.get(`${group.kind}::${group.name}`) ?? []}
            onDisk={onDisk}
            busy={busy}
            projectScope={projectScope}
            onAccept={onAccept}
          />
        ))}
      </div>
    </div>
  );
}
