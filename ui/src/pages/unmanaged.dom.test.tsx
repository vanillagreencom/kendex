// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, DriftRow, Scope } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import {
  ALL_MANAGED_TITLE,
  PLACE_UNCHECKED_TITLE,
  START_MANAGING_LABEL,
} from "@/lib/copy";
import { manageSharedBody, PROCEED_LABEL } from "@/lib/copy-in-the-way";
import { READ_LANDED } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { mount, settle } from "@/test/dom";
import { observed } from "@/test/observed";
import { UnmanagedPage } from "./unmanaged";

vi.mock("@/bindings", () => ({ commands: { auditAll: vi.fn() } }));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const ACME: Scope = { scope: "project", root: "/work/acme" };

const byHand = (name: string): DriftRow => ({
  kind: "skill",
  name,
  harness: "claude",
  state: "unmanaged",
  detail: `/work/acme/.claude/skills/${name}`,
  scope: ACME,
});

const view = (drift: DriftRow[]): AuditView => ({
  scope: ACME,
  drift,
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
});

/** The folder the shortcut resolves to, which is what adoption moves. */
const SHARED = "/work/acme/team-skills/gh";

/** Claude's shortcut at it, in the shape `sharedLinkOf` reads the scan in. */
const LINKED = observed({
  kind: "skill",
  name: "gh",
  harness: "claude",
  scope: ACME,
  path: "/work/acme/.claude/skills/gh",
  fileState: { state: "symlink", target: SHARED, broken: false },
  enabled: true,
  origin: null,
  description: null,
  tags: [],
  modifiedAt: null,
  vendor: null,
});

const button = (host: HTMLElement, label: string) =>
  [...host.querySelectorAll("button")].find(
    (el) => el.textContent?.trim() === label,
  );

const stage = (rows: AuditView[]) =>
  act(() => {
    useAuditStore.setState({
      views: rows,
      auditedAt: Date.now(),
      read: READ_LANDED,
    });
    useNavStore.setState({ unmanagedScope: ACME });
  });

beforeEach(() => {
  useAuditStore.setState({
    views: [],
    auditedAt: null,
    read: READ_LANDED,
  });
  useNavStore.setState({ unmanagedScope: null });
});

// Every button on this page adopts, and adopting writes to the filesystem
// from the rows it was handed. A place the audit could not read has rows
// nothing has confirmed still exist — files may have changed or gone since.
describe("a place the audit could not read", () => {
  const outcomes = [
    {
      name: "offers no adoption, and says why rather than claiming it is clean",
      reading: {
        ...view([byHand("gh"), byHand("lint")]),
        error: { kind: "lock-corrupt", message: "lock is not JSON" },
      },
      present: [PLACE_UNCHECKED_TITLE, "lock is not JSON"],
      absent: [START_MANAGING_LABEL, ALL_MANAGED_TITLE],
      noButtons: true,
    },
    {
      name: "offers the adoption once the place reads",
      reading: view([byHand("gh")]),
      present: ["gh", START_MANAGING_LABEL],
      absent: [PLACE_UNCHECKED_TITLE],
      noButtons: false,
    },
    {
      name: "says everything is managed when the place reads and holds nothing",
      reading: view([]),
      present: [ALL_MANAGED_TITLE],
      absent: [PLACE_UNCHECKED_TITLE],
      noButtons: false,
    },
  ] satisfies {
    name: string;
    reading: AuditView;
    present: string[];
    absent: string[];
    noButtons: boolean;
  }[];
  expect(outcomes).toHaveLength(3);
  it.each(outcomes)("$name", async (row) => {
    stage([row.reading]);
    const host = mount(<UnmanagedPage />);
    await settle();
    const text = host.textContent ?? "";
    expect(
      {
        present: row.present.filter((value) => text.includes(value)),
        absent: row.absent.filter((value) => text.includes(value)),
        buttons: row.noButtons ? host.querySelectorAll("button").length : null,
      },
      row.name,
    ).toEqual({
      present: row.present,
      absent: [],
      buttons: row.noButtons ? 0 : null,
    });
  });
});

// A folder a tool reads through a shortcut it set up moves whole, so this
// page asks first. The move deletes nothing, so its confirm is not red.
describe("an item a tool reads through a shortcut it set up", () => {
  it("does not style the move's confirm as a deletion", async () => {
    stage([view([byHand("gh")])]);
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [LINKED],
        missingProjects: [],
        readProjects: [],
        warnings: [],
      },
    });
    const host = mount(<UnmanagedPage />);
    await settle();

    await act(async () => button(host, START_MANAGING_LABEL)?.click());
    await settle();

    // The dialog is in a portal, off the page's own tree.
    const confirm = button(document.body, PROCEED_LABEL);
    expect(confirm).toBeDefined();
    expect(confirm?.className).not.toContain("bg-destructive");
    const body = manageSharedBody(SHARED, ["Claude Code"]);
    expect(document.body.textContent).toContain(body);
  });
});
