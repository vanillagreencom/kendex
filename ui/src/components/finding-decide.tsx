import { useState } from "react";
import type { DismissReason } from "@/bindings";
import { IgnoreDialog } from "@/components/ignore-dialog";
import { StatusLine } from "@/components/status-note";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { FEWER_ITEMS_LABEL } from "@/lib/copy";
import {
  earlierDecisionNote,
  IGNORE_LABEL,
  ignoreAllLabel,
  separatePiecesLabel,
  UNDECIDABLE_HERE,
} from "@/lib/copy-decisions";
import { abbreviateHome } from "@/lib/drift-merge";
import { harnessName, moreItemsLabel } from "@/lib/labels";
import type { EvidenceGroup } from "@/lib/reviewable";

/**
 * The button that rules on one piece of evidence — the same bytes carrying
 * the same finding, however many tools read them. It opens the reason
 * dialog and sends exactly this group's tokens; nothing about the row it
 * sits on can widen that.
 */
export function IgnoreButton({
  group,
  projectScope,
  busy,
  onDismiss,
}: {
  group: EvidenceGroup;
  projectScope: boolean;
  busy: boolean;
  onDismiss: (tokens: string[], reason: DismissReason) => void;
}) {
  const [open, setOpen] = useState(false);
  if (group.tokens.length === 0) {
    return (
      <span className="shrink-0 text-xs text-muted-foreground">
        {UNDECIDABLE_HERE}
      </span>
    );
  }
  return (
    <>
      <Button
        size="sm"
        variant="outline"
        className="shrink-0"
        disabled={busy}
        aria-label={`Ignore the finding on ${group.items[0].name}`}
        onClick={(event) => {
          event.stopPropagation();
          setOpen(true);
        }}
      >
        {IGNORE_LABEL}
      </Button>
      <IgnoreDialog
        open={open}
        onOpenChange={setOpen}
        count={group.tokens.length}
        subject={group.items[0].name}
        finding={group.finding.message}
        projectScope={projectScope}
        canTrustSource={group.canTrustSource}
        busy={busy}
        onConfirm={(reason) => {
          setOpen(false);
          onDismiss(group.tokens, reason);
        }}
      />
    </>
  );
}

/** One evidence group as a line a person can rule on: what it is on, where
 *  it is, and the button. The same file installed for three tools is one
 *  line naming all three, because that is one decision. */
export function EvidenceLine({
  group,
  projectScope,
  busy,
  onDismiss,
}: {
  group: EvidenceGroup;
  projectScope: boolean;
  busy: boolean;
  onDismiss: (tokens: string[], reason: DismissReason) => void;
}) {
  // A hook's full id — event, matcher, script — is what tells seven hooks
  // in one settings file apart; the short display name would not.
  const first = group.items[0];
  const name = first.name;
  const tools = [
    ...new Set(group.items.map((item) => harnessName(item.harness))),
  ];
  return (
    <div className="flex items-center gap-2.5 py-1.5">
      <Badge
        variant="outline"
        className="max-w-full shrink-0 truncate font-normal"
      >
        {name}
      </Badge>
      <span className="flex min-w-0 flex-1 flex-col text-xs text-muted-foreground">
        <span className="truncate">
          {tools.join(", ")}
          {" · "}
          {/* Every place, not the first: one decision settles this
              sentence wherever the item carries it, and a person deciding
              is owed the whole of what they are deciding about. */}
          <span className="font-mono">
            {group.locations.map(abbreviateHome).join(", ")}
          </span>
        </span>
        {group.earlier ? (
          <StatusLine tone="info">
            {earlierDecisionNote(group.earlier)}
          </StatusLine>
        ) : null}
      </span>
      <IgnoreButton
        group={group}
        projectScope={projectScope}
        busy={busy}
        onDismiss={onDismiss}
      />
    </div>
  );
}

const SHOWN_BY_DEFAULT = 5;

/**
 * The evidence behind one concern, when it spans more than one piece of
 * content. Twenty plugins tripping the same rule are twenty decisions, and
 * printing twenty rows with twenty buttons made the page unreadable — so
 * the whole set can be ruled on at once, and only the first few rows are
 * on screen unless you ask for the rest.
 */
export function EvidenceList({
  groups,
  finding,
  projectScope,
  busy,
  onDismiss,
}: {
  groups: EvidenceGroup[];
  /** The concern's own words, restated in the ignore-all dialog. */
  finding: string;
  projectScope: boolean;
  busy: boolean;
  onDismiss: (tokens: string[], reason: DismissReason) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const [ignoringAll, setIgnoringAll] = useState(false);
  const visible = expanded ? groups : groups.slice(0, SHOWN_BY_DEFAULT);
  const hidden = groups.length - visible.length;
  const allTokens = groups.flatMap((group) => group.tokens);

  return (
    <div className="flex flex-col text-[13px]">
      <div className="flex items-center justify-between gap-4 pb-1.5">
        <p className="font-medium text-foreground">
          {separatePiecesLabel(groups.length)}
        </p>
        {allTokens.length > 0 ? (
          <Button
            size="sm"
            variant="outline"
            disabled={busy}
            onClick={() => setIgnoringAll(true)}
          >
            {ignoreAllLabel(groups.length)}
          </Button>
        ) : null}
      </div>
      <div className="flex flex-col divide-y divide-border">
        {visible.map((group) => (
          <EvidenceLine
            key={group.tokens.join("|")}
            group={group}
            projectScope={projectScope}
            busy={busy}
            onDismiss={onDismiss}
          />
        ))}
      </div>
      {groups.length > SHOWN_BY_DEFAULT ? (
        <button
          type="button"
          onClick={() => setExpanded((open) => !open)}
          className="self-start pt-2 text-xs text-muted-foreground underline underline-offset-2 hover:text-foreground"
        >
          {expanded ? FEWER_ITEMS_LABEL : moreItemsLabel(hidden)}
        </button>
      ) : null}
      <IgnoreDialog
        open={ignoringAll}
        onOpenChange={setIgnoringAll}
        count={allTokens.length}
        subject={separatePiecesLabel(groups.length)}
        finding={finding}
        projectScope={projectScope}
        canTrustSource={groups.every((group) => group.canTrustSource)}
        busy={busy}
        onConfirm={(reason) => {
          setIgnoringAll(false);
          onDismiss(allTokens, reason);
        }}
      />
    </div>
  );
}
