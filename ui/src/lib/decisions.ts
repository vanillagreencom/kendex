// Pure derivations for the recorded-decisions list: what each row says,
// how the list orders itself, and which verb takes a record back.
import type { RecordedDecision, Scope } from "@/bindings";
import {
  acceptedPhrase,
  FORGET_LABEL,
  reasonPhrase,
  TAKE_BACK_LABEL,
} from "@/lib/copy-decisions";
import { WITHDRAW_LABEL } from "@/lib/copy-safety";
import { scopeName } from "@/lib/labels";
import { relativeTime } from "@/lib/relative-time";

/** Whose file a decision sits in. A project's kendex.toml is shared with
 *  everyone using the repository; the personal manifest is this machine's.
 *  Inheriting a teammate's decision is fine — inheriting it invisibly is
 *  not, so every row says which. */
export function decisionHome(scope: Scope, among: Scope[] = []): string {
  return scope.scope === "global"
    ? "yours, on this machine"
    : `in ${scopeName(scope, among)}'s kendex.toml, shared`;
}

export function decisionWhen(
  decision: RecordedDecision,
  now: number,
): string | null {
  const stamp =
    decision.record.kind === "accepted"
      ? decision.record.grantedAt
      : decision.record.dismissedAt;
  const at = Date.parse(stamp);
  return Number.isNaN(at) ? null : relativeTime(at, now);
}

/** The sentence under a decision's name: what was decided, when, whose. */
export function describeDecision(
  decision: RecordedDecision,
  now: number,
  /** Every place the list spans, so two projects sharing a folder name are
   *  named apart — a decision is about one repository's file. */
  among: Scope[] = [],
): string {
  const what =
    decision.record.kind === "accepted"
      ? acceptedPhrase(decision.record.findings)
      : reasonPhrase(decision.record.reason);
  return [
    what,
    decisionWhen(decision, now),
    decisionHome(decision.scope, among),
  ]
    .filter(Boolean)
    .join(" · ");
}

/** The finding a dismissal was about, as the current check words it — or
 *  nothing, once the finding is no longer reported. */
export function decisionDetail(decision: RecordedDecision): string | null {
  if (decision.record.kind !== "dismissed") return null;
  return decision.record.finding?.message ?? null;
}

const STATE_RANK = { active: 0, stale: 1, obsolete: 2 } as const;

/** Live decisions first, then the ones that no longer apply, then the ones
 *  about items that are gone — a person looks at what still counts before
 *  what needs clearing out. Ties keep the backend's order. */
export function sortDecisions(rows: RecordedDecision[]): RecordedDecision[] {
  return [...rows].sort(
    (a, b) => STATE_RANK[a.state.state] - STATE_RANK[b.state.state],
  );
}

/** Withdrawing an acceptance holds the item back again; taking a dismissal
 *  back brings the finding back; a record that no longer applies to
 *  anything is simply forgotten. */
export function revokeLabel(decision: RecordedDecision): string {
  if (decision.state.state !== "active") return FORGET_LABEL;
  return decision.record.kind === "accepted" ? WITHDRAW_LABEL : TAKE_BACK_LABEL;
}
