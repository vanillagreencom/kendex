// Pure grouping/dedupe logic for the safety wall: the engine emits one
// ItemSafety per installation, so a hook declared seven times or a plugin
// installed four times repeats the exact same finding — this collapses
// those repeats before anything renders.
import type {
  Finding,
  HarnessId,
  ItemKind,
  ItemSafety,
  Severity,
} from "@/bindings";
import { heldBack } from "@/lib/derive";
import { type Occurrence, openOccurrences } from "@/lib/reviewable";

// Shared so a collapsed row can lead with whichever finding or rule-group is
// most serious, without every caller re-deriving the same ranking.
export const SEVERITY_RANK: Record<Severity, number> = {
  low: 0,
  medium: 1,
  high: 2,
  critical: 3,
};

export interface SafetyGroups {
  /** verdict "block" — held back or overridden; always rendered per item,
   *  every finding shown whatever was decided about it. */
  blocked: ItemSafety[];
  /** Installed and not held back, with at least one finding nobody has
   *  ruled on — the rows "Needs your decision" reads its findings from. */
  open: ItemSafety[];
  /** Installed with findings, every one of them decided — dismissed, or
   *  covered by an acceptance. Nothing left to ask, and not clean either. */
  settled: ItemSafety[];
  /** Nothing was found at all — collapsed to a single summary line. */
  clean: ItemSafety[];
}

// A row carrying findings is never "clean", whatever its verdict says. A
// verdict answers "does this install"; the publisher settling every finding
// on an item makes it install and leaves the findings there to be read. Ask
// the findings, not the verdict, or an item carrying settled criticals reads
// as nothing to report.
export function partitionSafety(rows: ItemSafety[]): SafetyGroups {
  const blocked: ItemSafety[] = [];
  const open: ItemSafety[] = [];
  const settled: ItemSafety[] = [];
  const clean: ItemSafety[] = [];
  for (const row of rows) {
    if (row.verdict === "block") blocked.push(row);
    else if (row.findings.length === 0) clean.push(row);
    else if (openOccurrences([row]).length > 0) open.push(row);
    else settled.push(row);
  }
  // Rows nothing can be done about yet lead; an already-accepted one follows.
  blocked.sort((a, b) => Number(heldBack(b)) - Number(heldBack(a)));
  return { blocked, open, settled, clean };
}

export interface FindingItem {
  kind: ItemKind;
  name: string;
  harness: HarnessId;
}

export interface FindingGroup extends Finding {
  /** Every place this one identity was found, in the order they were
   *  reported. `location` is the first of them. */
  locations: string[];
  items: FindingItem[];
  /** The exact occurrences behind the group — what a decision targets.
   *  Grouping is presentation; these are the things a person rules on. */
  occurrences: Occurrence[];
}

/** Dedupes open findings for display, by the identity a decision is made
 *  against rather than by where each one was found.
 *
 *  One decision covers every occurrence of one rule and one sentence within
 *  an item, so drawing them as separate rows would let a person act on the
 *  row they read and silently clear rows in files they never opened. One
 *  row, with every place it was found listed under it. */
export function groupFindings(open: Occurrence[]): FindingGroup[] {
  const groups = new Map<string, FindingGroup>();
  for (const occurrence of open) {
    const { row, finding } = occurrence;
    // The identity a decision is made against — the rule and the sentence,
    // exactly what `Finding::fingerprint` hashes. Keying on the location
    // too would draw one decision as several rows, and acting on the row a
    // person read would clear rows in files they never opened.
    const key = `${finding.rule}::${finding.message}`;
    let group = groups.get(key);
    if (!group) {
      group = { ...finding, locations: [], items: [], occurrences: [] };
      groups.set(key, group);
    }
    if (!group.locations.includes(finding.location)) {
      group.locations.push(finding.location);
    }
    // One identity, read in two places that weigh differently — a body and
    // a supporting file. The row leads with the worse of them, the way the
    // held-back panel's groups do.
    if (SEVERITY_RANK[finding.severity] > SEVERITY_RANK[group.severity]) {
      group.severity = finding.severity;
    }
    group.items.push({
      kind: row.kind,
      name: row.name,
      harness: row.harness,
    });
    group.occurrences.push(occurrence);
  }
  return [...groups.values()];
}

export interface ConcernGroup {
  rule: string;
  /** The most serious severity any of this rule's findings carried. */
  severity: Severity;
  items: FindingItem[];
  findings: FindingGroup[];
}

// One rule firing in four places is one concern to a person, not four —
// "downloads and runs code from the internet" said once, with everything it
// touched behind it, beats the same sentence stacked four times. Concerns
// come back worst-first so the list reads in order of what to look at.
export function groupByConcern(groups: FindingGroup[]): ConcernGroup[] {
  const ordered: ConcernGroup[] = [];
  const byRule = new Map<string, ConcernGroup>();
  const seenItems = new Map<string, Set<string>>();
  for (const group of groups) {
    let concern = byRule.get(group.rule);
    if (!concern) {
      concern = {
        rule: group.rule,
        severity: group.severity,
        items: [],
        findings: [],
      };
      byRule.set(group.rule, concern);
      seenItems.set(group.rule, new Set());
      ordered.push(concern);
    }
    concern.findings.push(group);
    if (SEVERITY_RANK[group.severity] > SEVERITY_RANK[concern.severity]) {
      concern.severity = group.severity;
    }
    const seen = seenItems.get(group.rule);
    if (!seen) throw new Error(`no item set for concern ${group.rule}`);
    for (const item of group.items) {
      const key = `${item.kind}:${item.name}:${item.harness}`;
      if (seen.has(key)) continue;
      seen.add(key);
      concern.items.push(item);
    }
  }
  return ordered.sort(
    (a, b) => SEVERITY_RANK[b.severity] - SEVERITY_RANK[a.severity],
  );
}

/** Distinct message+fix pairs within a concern, each with every place it fired. */
export interface ConcernDetail {
  finding: Finding;
  locations: string[];
}

// The same rule usually emits the same sentence everywhere it fires, so the
// expansion shows that sentence once and lists the places under it.
export function concernDetails(concern: ConcernGroup): ConcernDetail[] {
  const ordered: ConcernDetail[] = [];
  const byMessage = new Map<string, ConcernDetail>();
  for (const finding of concern.findings) {
    const key = `${finding.message}::${finding.remediation}`;
    let detail = byMessage.get(key);
    if (!detail) {
      detail = { finding, locations: [] };
      byMessage.set(key, detail);
      ordered.push(detail);
    }
    for (const location of finding.locations) {
      if (!detail.locations.includes(location)) {
        detail.locations.push(location);
      }
    }
  }
  return ordered;
}
