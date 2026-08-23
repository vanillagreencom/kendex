// Grouping logic for the "Held back" panel specifically — split out of
// group-findings.ts to stay under the file's line cap. A held-back skill
// installed on several harnesses that share the same files on disk, or a
// single rule firing at several locations in one skill, otherwise renders
// as several verbatim repeats of the same problem; this collapses both
// before anything renders.
import type {
  DismissReason,
  Finding,
  FindingDecision,
  ItemKind,
  ItemSafety,
  Severity,
} from "@/bindings";
import { SEVERITY_RANK } from "@/lib/group-findings";

export interface RuleGroup {
  rule: string;
  severity: Severity;
  message: string;
  remediation: string;
  locations: string[];
  /** What this entry was grouped by, so a list of them can be keyed by the
   *  same thing that made them distinct entries — never by a subset of it,
   *  which is how two entries come to share one key. */
  key: string;
  /** The publisher's record, where one settled every occurrence behind this
   *  group. A held-back item's score already excludes them, so a line that
   *  printed a plain fix here would be asking the reader to act on
   *  something nobody is counting. Absent where any occurrence is still an
   *  open question. */
  settledBy: SettledBy | null;
}

export interface SettledBy {
  reason: DismissReason;
  dismissedAt: string;
  publisher: string;
}

// Within one item's finding list, the same rule can fire once per line it
// matched (a hook shelling through the same wrapper at four call sites) —
// same message, same fix, four locations. This collapses those into one
// entry so the fix sentence prints once instead of once per location.
// `decisions` has no default on purpose: it is what carries the publisher's
// name onto a held-back item's settled findings, and a default would let the
// one caller drop it with nothing to notice. The type checker holds the
// wiring instead.
export function groupFindingsByRule(
  findings: Finding[],
  decisions: FindingDecision[],
): RuleGroup[] {
  const ordered: RuleGroup[] = [];
  const byKey = new Map<string, RuleGroup>();
  const decided = new Map<string, (SettledBy | null)[]>();
  for (const [index, finding] of findings.entries()) {
    const key = `${finding.rule}::${finding.message}::${finding.remediation}`;
    let group = byKey.get(key);
    if (!group) {
      group = {
        key,
        rule: finding.rule,
        severity: finding.severity,
        message: finding.message,
        remediation: finding.remediation,
        locations: [],
        settledBy: null,
      };
      byKey.set(key, group);
      ordered.push(group);
      decided.set(key, []);
    }
    if (SEVERITY_RANK[finding.severity] > SEVERITY_RANK[group.severity]) {
      group.severity = finding.severity;
    }
    group.locations.push(finding.location);
    const state = decisions[index]?.state;
    decided.get(key)?.push(
      state?.state === "author-dismissed"
        ? {
            reason: state.reason,
            dismissedAt: state.dismissedAt,
            publisher: state.publisher,
          }
        : null,
    );
  }
  // A group speaks for the publisher only if every occurrence behind it
  // does: one occurrence nobody has ruled on and the reader still has
  // something to do here.
  for (const group of ordered) {
    const states = decided.get(group.key) ?? [];
    group.settledBy =
      states.length > 0 && states.every((state) => state !== null)
        ? states[0]
        : null;
  }
  return ordered;
}

export interface BlockedGroup {
  kind: ItemKind;
  name: string;
  /** One row per harness this exact finding set was seen on. */
  rows: ItemSafety[];
  findingGroups: RuleGroup[];
}

// The engine emits one blocked ItemSafety per harness a skill is installed
// on. When two harnesses share the same files on disk, they carry the exact
// same rule hitting the exact same locations — rendered separately that's
// two verbatim panels for one logical problem. This merges rows sharing
// (kind, name) whose finding sets are identical (same rule, message,
// remediation, and location, as a multiset) into one entry carrying every
// harness it was seen on. A name that means something different per
// harness — same skill name, different files, different findings — stays
// separate, since collapsing it would hide a real difference.
const itemKey = (row: ItemSafety) => `${row.kind}::${row.name}`;
const rowKey = (row: ItemSafety) => `${row.kind}::${row.name}::${row.harness}`;

export interface HeldBackMerge {
  /** What the panel renders: every observed blocked row, plus the
   *  plan-time refusals with no on-disk counterpart (a fresh install the
   *  gate stopped before it reached disk). */
  display: ItemSafety[];
  /** Plan-time held-back rows by `kind::name` — present exactly when the
   *  next apply wants to write this item, which is when accepting can do
   *  anything. A purely observed row is unmanaged; its path is adoption. */
  plannedByItem: Map<string, ItemSafety[]>;
  /** Row identities (`kind::name::harness`) that exist on disk. */
  onDisk: Set<string>;
}

// The two lists describe different bytes: `observed` is what a tool would
// load right now, `heldBack` is what the plan would write and refuses to.
// The panel shows the union — a fresh blocked install has no observed row
// at all — and the accept action draws its hash from the plan-time side,
// because that is the hash the gate checks (`granted()` in engine/gate.rs).
export function mergeHeldBack(
  observed: ItemSafety[],
  heldBack: ItemSafety[],
): HeldBackMerge {
  const onDisk = new Set(observed.map(rowKey));
  const plannedByItem = new Map<string, ItemSafety[]>();
  for (const row of heldBack) {
    const rows = plannedByItem.get(itemKey(row)) ?? [];
    rows.push(row);
    plannedByItem.set(itemKey(row), rows);
  }
  const display = [
    ...observed,
    ...heldBack.filter((row) => !onDisk.has(rowKey(row))),
  ];
  return { display, plannedByItem, onDisk };
}

/** How much of the review hash a token carries — mirrors SHOWN_HASH in
 *  engine/gate.rs; a shorter prefix grants nothing. */
const TOKEN_HASH_CHARS = 12;

// One token per distinct content: a skill shared by three tools is one
// hash and one decision, while divergent per-tool variants each need
// their own — a single token would silently accept only part of the group.
// A row whose bytes could not be read has no hash to accept against, and a
// token without one would grant a review of content nobody can name.
export function acceptTokens(planned: ItemSafety[]): string[] {
  return [
    ...new Set(
      planned
        .filter((row) => row.reviewHash !== null)
        .map(
          (row) => `${row.name}@${row.reviewHash?.slice(0, TOKEN_HASH_CHARS)}`,
        ),
    ),
  ];
}

// Who settled one occurrence, as a merge key. A decision is part of what a
// row says, not a detail hanging off it: two harnesses whose findings match
// but whose decisions do not are two things to tell the reader, and the
// panel's attribution line is the disclosure the publisher's review is
// justified by. Reading it off whichever row arrived first would credit a
// publisher for somebody else's dismissal, or drop their review because
// another harness had one of its own. The timestamp is left out: the same
// record read on two harnesses carries the same date, and a personal
// dismissal made a second apart is still the same answer.
function attribution(decision: FindingDecision | undefined): string {
  const state = decision?.state;
  if (!state) return "undecided";
  return state.state === "author-dismissed"
    ? `${state.state}::${state.publisher}::${state.reason}`
    : state.state;
}

export function groupBlocked(blocked: ItemSafety[]): BlockedGroup[] {
  const ordered: BlockedGroup[] = [];
  const byKey = new Map<string, BlockedGroup>();
  for (const row of blocked) {
    const setKey = row.findings
      .map(
        (f, index) =>
          `${f.rule}::${f.message}::${f.remediation}::${f.location}::${attribution(row.decisions[index])}`,
      )
      .sort()
      .join("|");
    const key = `${row.kind}::${row.name}::${setKey}`;
    let group = byKey.get(key);
    if (!group) {
      group = {
        kind: row.kind,
        name: row.name,
        rows: [],
        // Sound to read from this row alone: every row that merges here
        // carries the same findings decided the same way, which is what
        // the key above is for.
        findingGroups: groupFindingsByRule(row.findings, row.decisions),
      };
      byKey.set(key, group);
      ordered.push(group);
    }
    group.rows.push(row);
  }
  return ordered;
}

// One held-back rule reuses the warn list's finding anatomy exactly — same
// severity lane, same order, same wording — so the two lists read as one
// system rather than two dialects of the same information.
export function ruleGroupAsFinding(group: RuleGroup): Finding {
  return {
    rule: group.rule,
    severity: group.severity,
    location: group.locations[0] ?? "",
    message: group.message,
    remediation: group.remediation,
  };
}

export function leadRuleGroup(groups: RuleGroup[]): RuleGroup {
  return groups.reduce((lead, group) =>
    SEVERITY_RANK[group.severity] > SEVERITY_RANK[lead.severity] ? group : lead,
  );
}
