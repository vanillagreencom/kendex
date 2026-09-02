// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, DriftRow, ObservedItem, Scope } from "@/bindings";
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
const LINKED = {
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
} satisfies ObservedItem;

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
  it("offers no adoption, and says why rather than claiming it is clean", async () => {
    stage([
      {
        ...view([byHand("gh"), byHand("lint")]),
        error: { kind: "lock-corrupt", message: "lock is not JSON" },
      },
    ]);
    const host = mount(<UnmanagedPage />);
    await settle();

    expect(host.textContent).toContain(PLACE_UNCHECKED_TITLE);
    expect(host.textContent).toContain("lock is not JSON");
    expect(host.textContent).not.toContain(START_MANAGING_LABEL);
    // "Everything is managed" is the one thing this page must not say about
    // a place whose contents nothing has read.
    expect(host.textContent).not.toContain(ALL_MANAGED_TITLE);
    expect(host.querySelectorAll("button")).toHaveLength(0);
  });

  // The controls, so the absence above is the error's doing and not the
  // page having nothing to show either way.
  it("offers the adoption once the place reads", async () => {
    stage([view([byHand("gh")])]);
    const host = mount(<UnmanagedPage />);
    await settle();

    expect(host.textContent).toContain("gh");
    expect(host.textContent).toContain(START_MANAGING_LABEL);
    expect(host.textContent).not.toContain(PLACE_UNCHECKED_TITLE);
  });

  it("says everything is managed when the place reads and holds nothing", async () => {
    stage([view([])]);
    const host = mount(<UnmanagedPage />);
    await settle();

    expect(host.textContent).toContain(ALL_MANAGED_TITLE);
    expect(host.textContent).not.toContain(PLACE_UNCHECKED_TITLE);
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
        warnings: [],
      },
    });
    const host = mount(<UnmanagedPage />);
    await settle();

    await act(async () => button(host, START_MANAGING_LABEL)?.click());
    await settle();

    // The dialog is in a portal, off the page's own tree.
    const confirm = button(document.body, PROCEED_LABEL);
    expect(confirm?.className).not.toContain("bg-destructive");
    // Read off the export: a body compared to its own words pins nothing.
    const body = manageSharedBody(SHARED, ["Claude Code"]);
    expect(body).toContain("Nothing is deleted");
    expect(document.body.textContent).toContain(body);
  });
});
