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
// one the manifest carries.
describe("the start-of-session note's state at a project", () => {
  it.each<{
    case: string;
    items: ObservedItem[];
    views: AuditView[];
    expected: "off" | "waiting" | "on";
  }>([
    { case: "nothing read", items: [], views: [], expected: "off" },
    {
      case: "the hook is rendered here",
      items: [hook(`SessionStart:*:${SESSION_NOTE_HOOK}`)],
      views: [],
      expected: "on",
    },
    {
      case: "the hook is declared and nothing rendered it",
      items: [],
      views: [view([missing(SESSION_NOTE_HOOK)])],
      expected: "waiting",
    },
    {
      case: "rendered outranks a stale declaration row",
      items: [hook(`SessionStart:*:${SESSION_NOTE_HOOK}`)],
      views: [view([missing(SESSION_NOTE_HOOK)])],
      expected: "on",
    },
    {
      // The declaration was removed and the install record still names
      // it: nothing asks for the note any more, so nothing is waiting.
      case: "an orphaned record of the hook is not a declaration",
      items: [],
      views: [view([{ ...missing(SESSION_NOTE_HOOK), state: "orphaned" }])],
      expected: "off",
    },
    {
      case: "another hook here is not this one",
      items: [hook("SessionStart:*:lint")],
      views: [view([missing("lint")])],
      expected: "off",
    },
    {
      case: "the hook at another project does not count",
      items: [hook(`SessionStart:*:${SESSION_NOTE_HOOK}`, "/work/other")],
      views: [view([missing(SESSION_NOTE_HOOK)], "/work/other")],
      expected: "off",
    },
  ])("$case", ({ items, views, expected }) => {
    expect(sessionNoteState(items, views, ROOT)).toBe(expected);
  });
});
