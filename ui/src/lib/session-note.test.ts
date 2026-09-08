import { describe, expect, it } from "vitest";
import type { AuditView, DriftRow, ObservedItem } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { SESSION_NOTE_HOOK, sessionNoteState } from "./session-note";

const ROOT = "/work/acme";

const hook = (name: string, root = ROOT): ObservedItem => ({
  kind: "hook",
  name,
  harness: "claude",
  scope: { scope: "project", root },
  path: `${root}/.claude/settings.json`,
  fileState: { state: "file" },
  enabled: null,
  origin: null,
  description: null,
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

// One state per row: what the scan and the audit hold, and the word the
// card gets. The rendered name is how `scan/hooks.rs` spells a
// registration, event and matcher first; the declared name is the bare
// one the manifest carries. Null is no word at all: the audit has not
// spoken for the place, on the two channels the count beside it reads.
describe("the start-of-session note's state at a project", () => {
  it("reads the project hook state", () => {
    const rows: {
      case: string;
      items: ObservedItem[];
      view: AuditView | undefined;
      failure?: string;
      expected: "off" | "waiting" | "on" | null;
    }[] = [
      { case: "nothing read", items: [], view: undefined, expected: null },
      {
        case: "the audit failed, whatever view it kept",
        items: [],
        view: view([]),
        failure: "offline",
        expected: null,
      },
      {
        case: "the place could not be read",
        items: [],
        view: { ...view([]), error: { kind: "other", message: "denied" } },
        expected: null,
      },
      {
        case: "the audit read the place and found nothing",
        items: [],
        view: view([]),
        expected: "off",
      },
      {
        case: "the hook is rendered here",
        items: [hook(`SessionStart:*:${SESSION_NOTE_HOOK}`)],
        view: undefined,
        expected: "on",
      },
      {
        case: "the hook is declared and nothing rendered it",
        items: [],
        view: view([missing(SESSION_NOTE_HOOK)]),
        expected: "waiting",
      },
      {
        // The lock records it and the settings entry is gone: declared,
        // not in place, and the next apply puts it back.
        case: "the hook is declared and its registration went stale",
        items: [],
        view: view([{ ...missing(SESSION_NOTE_HOOK), state: "stale" }]),
        expected: "waiting",
      },
      {
        case: "rendered outranks a stale declaration row",
        items: [hook(`SessionStart:*:${SESSION_NOTE_HOOK}`)],
        view: view([missing(SESSION_NOTE_HOOK)]),
        expected: "on",
      },
      {
        // The declaration was removed and the install record still names
        // it: nothing asks for the note any more, so nothing is waiting.
        case: "an orphaned record of the hook is not a declaration",
        items: [],
        view: view([{ ...missing(SESSION_NOTE_HOOK), state: "orphaned" }]),
        expected: "off",
      },
      {
        case: "another hook here is not this one",
        items: [hook("SessionStart:*:lint")],
        view: view([missing("lint")]),
        expected: "off",
      },
      {
        case: "the hook at another project does not count",
        items: [hook(`SessionStart:*:${SESSION_NOTE_HOOK}`, "/work/other")],
        view: view([]),
        expected: "off",
      },
    ];
    expect(rows.length, "session note state table is empty").toBeGreaterThan(0);
    for (const row of rows) {
      expect(
        sessionNoteState(row.items, row.view, row.failure ?? null, ROOT),
        row.case,
      ).toBe(row.expected);
    }
  });
});
