import { describe, expect, it } from "vitest";
import type { AuditView, DriftRow, HarnessId, ObservedItem } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import type { OriginOf } from "@/lib/package-identity";
import { observed } from "@/test/observed";
import { CHECK_HOOK, checksStanding } from "./package-checks";

const ROOT = "/work/acme";
const TARGETS: HarnessId[] = ["claude", "pi"];

/** What the join says about an installation kendex itself put there. */
const OURS: OriginOf = () => ({
  origin: "own",
  forkedFrom: null,
  source: "local",
});

const hook = (
  name: string,
  harness: HarnessId = "claude",
  root = ROOT,
): ObservedItem =>
  observed({
    kind: "hook",
    name,
    harness,
    scope: { scope: "project", root },
    path: `${root}/.claude/settings.json`,
    fileState: { state: "file" },
    enabled: null,
    origin: null,
    summary: null,
    action: null,
    tags: [],
    modifiedAt: null,
    vendor: null,
  });

const view = (drift: DriftRow[], root = ROOT): AuditView => ({
  scope: { scope: "project", root },
  drift,
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
});

const missing = (name: string): DriftRow => ({
  kind: "hook",
  name,
  harness: "claude",
  scope: { scope: "project", root: ROOT },
  state: "missing",
  detail: "not registered yet",
});

const rendered = (harness: HarnessId) =>
  hook(`SessionStart:*:${CHECK_HOOK}`, harness);

// One state per row: what the scan and the audit hold, and the state the
// card gets. The rendered name is how `scan/hooks.rs` spells a
// registration, event and matcher first; the declared name is the bare one
// the manifest carries. "unknown" is a state, not an absence: it is what
// the card says while nothing has established the answer.
describe("where a project's package checks stand", () => {
  it("reads the state and the per-tool coverage", () => {
    const rows: {
      case: string;
      items: ObservedItem[];
      view: AuditView | undefined;
      failure?: string;
      targets?: HarnessId[] | null;
      /** Where the join says each observation came from. Absent means
       *  kendex's own, which is what every row but the two about a
       *  claimed name is about. */
      origin?: OriginOf | null;
      expected: { state: string; running: HarnessId[]; waiting: HarnessId[] };
    }[] = [
      {
        case: "nothing read",
        items: [],
        view: undefined,
        targets: null,
        expected: { state: "unknown", running: [], waiting: [] },
      },
      {
        case: "the audit failed, whatever view it kept",
        items: [],
        view: view([]),
        failure: "offline",
        expected: { state: "unknown", running: [], waiting: [] },
      },
      {
        case: "the place could not be read",
        items: [],
        view: { ...view([]), error: { kind: "other", message: "denied" } },
        expected: { state: "unknown", running: [], waiting: [] },
      },
      {
        case: "the audit read the place and found nothing",
        items: [],
        view: view([]),
        expected: { state: "off", running: [], waiting: TARGETS },
      },
      {
        case: "every supported tool runs it",
        items: [rendered("claude"), rendered("pi")],
        view: undefined,
        expected: { state: "on", running: TARGETS, waiting: [] },
      },
      {
        // The whole point of reading per tool: one registration says one
        // tool is covered and can never say the other is.
        case: "one supported tool runs it and the other does not",
        items: [rendered("claude")],
        view: view([]),
        expected: { state: "incomplete", running: ["claude"], waiting: ["pi"] },
      },
      {
        case: "declared and nothing rendered it",
        items: [],
        view: view([missing(CHECK_HOOK)]),
        expected: { state: "incomplete", running: [], waiting: TARGETS },
      },
      {
        case: "declared and its registration went stale",
        items: [],
        view: view([{ ...missing(CHECK_HOOK), state: "stale" }]),
        expected: { state: "incomplete", running: [], waiting: TARGETS },
      },
      {
        // The declaration was removed and the install record still names
        // it: nothing asks for the check any more.
        case: "an orphaned record of it is not a declaration",
        items: [],
        view: view([{ ...missing(CHECK_HOOK), state: "orphaned" }]),
        expected: { state: "off", running: [], waiting: TARGETS },
      },
      {
        case: "another hook here is not this one",
        items: [hook("SessionStart:*:lint")],
        view: view([missing("lint")]),
        expected: { state: "off", running: [], waiting: TARGETS },
      },
      {
        case: "the check at another project does not count",
        items: [hook(`SessionStart:*:${CHECK_HOOK}`, "claude", "/work/other")],
        view: view([]),
        expected: { state: "off", running: [], waiting: TARGETS },
      },
      {
        // The name is a marketplace package's here. Reading it as the
        // check would report somebody else's hook as ours.
        case: "a hook of that name from a marketplace",
        items: [rendered("claude"), rendered("pi")],
        view: view([]),
        origin: () => ({ origin: "marketplace", source: "cat", repo: "o/c" }),
        expected: { state: "unknown", running: [], waiting: [] },
      },
      {
        // A hook of that name, and no read yet says whose it is.
        case: "a hook of that name nothing can attribute",
        items: [rendered("claude"), rendered("pi")],
        view: view([]),
        origin: null,
        expected: { state: "unknown", running: [], waiting: [] },
      },
      {
        // Nothing wearing the name, so there is nothing to attribute and
        // the missing join decides nothing.
        case: "no hook of that name, and no join yet",
        items: [],
        view: view([]),
        origin: null,
        expected: { state: "off", running: [], waiting: TARGETS },
      },
    ];
    expect(rows.length, "package checks state table is empty").toBeGreaterThan(
      0,
    );
    for (const row of rows) {
      expect(
        checksStanding(
          row.items,
          row.view,
          row.failure ?? null,
          ROOT,
          row.targets === undefined ? TARGETS : row.targets,
          row.origin === undefined ? OURS : row.origin,
        ),
        row.case,
      ).toEqual(row.expected);
    }
  });
});
