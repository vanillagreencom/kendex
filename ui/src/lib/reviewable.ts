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
  DismissReason,
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

/** The findings the publishing catalog settled rather than the person
 *  reading this. Kept apart because "you decided this" and "whoever you
 *  installed it from decided this" are not the same sentence — and because
 *  showing them is the whole justification for honouring them at all. */
export function authorOccurrences(rows: ItemSafety[]): Occurrence[] {
  return rows
    .flatMap(occurrences)
    .filter(
      (occurrence) => occurrence.decision.state.state === "author-dismissed",
    );
}

export function authorSettledCount(rows: ItemSafety[]): number {
  return authorOccurrences(rows).length;
}

/** One finding the publisher settled, wherever it was found. */
export interface PublisherGroup {
  /** What this entry was grouped by, so a list of them can be keyed by the
   *  same thing that made them distinct entries. Rebuilding a key at the
   *  render site is how two entries come to share one: rule and location
   *  used to tell findings apart, and identity is the rule and the sentence
   *  now, so one line matching a rule twice is two entries under one key
   *  and React is free to show either one's decision against the other. */
  key: string;
  finding: Finding;
  /** Every distinct place this decision covers, in the order they were
   *  found. A record settles a sentence wherever the item carries it, so
   *  showing the first and dropping the rest tells a person a publisher
   *  ruled on one line when they ruled on five — and what this list exists
   *  to disclose is exactly how far somebody else's judgement reaches. */
  locations: string[];
  reason: DismissReason;
  dismissedAt: string;
  publisher: string;
  items: EvidenceItem[];
}

/** The publisher's settled findings, one entry per decision rather than one
 *  per installation: a shared skill tree is what three tools load, and the
 *  same sentence printed three times reads as three problems. Grouped the
 *  way the decision zone groups evidence — the same bytes carrying the same
 *  finding is one thing to say, with every tool that loads it named.
 *
 *  The item and the publisher are part of the key, never the harness. The
 *  harness is what makes one file three rows, so leaving it out is the
 *  grouping. The other two are not: two differently named commands can
 *  carry identical bytes, and a review hash seals the kind and the bytes
 *  alone — merging them would print one catalog's name over content it
 *  never saw, which is the one thing this list exists to state.
 *
 *  So are the reason and the date, for the same reason. Two tools can sit
 *  at revisions whose bytes are identical while the record between them
 *  changed — `wrong-call` re-recorded as `intended` — and an entry can
 *  only show one reason and one date. Merging those prints a judgement the
 *  publisher made for one tool over the other, on the one surface built to
 *  disclose what they actually decided. */
export function publisherGroups(rows: ItemSafety[]): PublisherGroup[] {
  const ordered: PublisherGroup[] = [];
  const byEvidence = new Map<string, PublisherGroup>();
  for (const { row, finding, decision } of authorOccurrences(rows)) {
    if (decision.state.state !== "author-dismissed") continue;
    const content = row.reviewHash ?? `${row.kind}:${row.name}`;
    const { publisher, reason, dismissedAt } = decision.state;
    const key = `${content}::${row.kind}:${row.name}::${publisher}::${reason}::${dismissedAt}::${decision.fingerprint}`;
    let group = byEvidence.get(key);
    if (!group) {
      group = {
        key,
        finding,
        locations: [],
        reason,
        dismissedAt,
        publisher,
        items: [],
      };
      byEvidence.set(key, group);
      ordered.push(group);
    }
    group.items.push({ kind: row.kind, name: row.name, harness: row.harness });
    if (!group.locations.includes(finding.location)) {
      group.locations.push(finding.location);
    }
  }
  return ordered;
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
  /** Every distinct place this evidence was found. One decision covers all
   *  of them, so a person deciding is shown all of them. */
  locations: string[];
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
    // The item is in the key and the harness is not. The harness is what
    // makes one file three rows, so leaving it out is the grouping. The
    // item is not: a review hash seals the kind and the bytes alone, so two
    // differently named commands with identical bodies share one — and
    // merging them puts one row's name over a decision that would settle
    // the other, with its token in the same batch.
    const key = `${content}::${row.kind}:${row.name}::${decision.fingerprint}`;
    const existing = byEvidence.get(key);
    const group: EvidenceGroup = existing ?? {
      finding,
      locations: [],
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
    if (!group.locations.includes(finding.location)) {
      group.locations.push(finding.location);
    }
    if (row.provenance == null) group.canTrustSource = false;
  }
  return ordered;
}
