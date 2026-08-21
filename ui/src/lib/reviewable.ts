// The presentation of "what still needs a person" — Review visibility,
// the sidebar and Home counts, the scope summaries and the finished state
// all read this, so none of them can quote a different number.
//
// The counting semantics are owned by core (`engine/reviewable.rs`), which
// the drift snapshot and the session-start check read; this file mirrors
// them for the surfaces that need the groups and tokens, not just the
// number, and core's tests mirror reviewable.test.ts scenario for scenario
// so the two can never quietly disagree.
//
// Two things need a person: an install the gate is holding back (settled
// by accepting or removing the item), and a finding on installed content
// nobody has ruled on yet (settled by dismissing it). A dismissed or
// accepted finding is not one of them, and neither is a held-back item's
// individual finding — that item is counted once, as held back.
import type {
  Finding,
  FindingDecision,
  HarnessId,
  ItemKind,
  ItemSafety,
} from "@/bindings";
import { heldBack } from "@/lib/derive";

/** One finding on one installation, with what has been decided about it. */
export interface Occurrence {
  row: ItemSafety;
  finding: Finding;
  decision: FindingDecision;
}

function occurrences(row: ItemSafety): Occurrence[] {
  return row.findings.map((finding, index) => {
    const decision = row.decisions[index];
    if (!decision) {
      throw new Error(
        `${row.kind} ${row.name}: finding ${index} has no decision beside it`,
      );
    }
    return { row, finding, decision };
  });
}

/** Findings still waiting on a person, on items the gate is not holding
 *  back. A held-back item's findings are decided by accepting or removing
 *  the item, so they are not offered here. */
export function openOccurrences(rows: ItemSafety[]): Occurrence[] {
  return rows
    .filter((row) => !heldBack(row))
    .flatMap(occurrences)
    .filter((occurrence) => occurrence.decision.state.state === "open");
}

/** Findings a person has already ruled on, one way or the other. */
export function settledCount(rows: ItemSafety[]): number {
  return rows
    .flatMap(occurrences)
    .filter((occurrence) => occurrence.decision.state.state !== "open").length;
}

/** Of those, the ones the publishing catalog settled rather than the person
 *  reading this. Counted apart because "you decided this" and "whoever you
 *  installed it from decided this" are not the same sentence. */
export function authorSettledCount(rows: ItemSafety[]): number {
  return rows
    .flatMap(occurrences)
    .filter(
      (occurrence) => occurrence.decision.state.state === "author-dismissed",
    ).length;
}

export interface EvidenceItem {
  kind: ItemKind;
  name: string;
  harness: HarnessId;
}

/** Occurrences that are the same evidence: the same bytes, by review
 *  hash, carrying the same finding, by fingerprint — one file read through
 *  several tools. One decision legitimately covers all of them, because no
 *  rule reads the tool. Anything else is a different question and stays a
 *  separate group, however alike the sentence looks. */
export interface EvidenceGroup {
  finding: Finding;
  /** The tokens a dismissal of this group sends — one per installation.
   *  Empty where the content cannot be read here: the finding still needs
   *  a person, it just cannot be settled from this machine, and the page
   *  says so rather than dropping it from the count. */
  tokens: string[];
  items: EvidenceItem[];
  /** Whether every installation here can name where its content came
   *  from — the one thing a trusted-source dismissal needs. */
  canTrustSource: boolean;
  /** Why an earlier decision on this finding stopped applying, when there
   *  was one — the person deciding again deserves to know it is again. */
  earlier: string | null;
}

export function evidenceGroups(open: Occurrence[]): EvidenceGroup[] {
  const ordered: EvidenceGroup[] = [];
  const byEvidence = new Map<string, EvidenceGroup>();
  for (const { row, finding, decision } of open) {
    const content = row.reviewHash ?? `${row.kind}:${row.name}:${row.harness}`;
    const key = `${content}::${decision.fingerprint}`;
    const existing = byEvidence.get(key);
    const group: EvidenceGroup = existing ?? {
      finding,
      tokens: [],
      items: [],
      canTrustSource: true,
      earlier:
        decision.state.state === "open"
          ? (decision.state.earlier ?? null)
          : null,
    };
    if (!existing) {
      byEvidence.set(key, group);
      ordered.push(group);
    }
    if (decision.token) group.tokens.push(decision.token);
    group.items.push({ kind: row.kind, name: row.name, harness: row.harness });
    if (row.provenance == null) group.canTrustSource = false;
  }
  return ordered;
}
