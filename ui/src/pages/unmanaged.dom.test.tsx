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
import {
  manageConfirmTitle,
  manageSharedBody,
  PROCEED_LABEL,
} from "@/lib/copy-in-the-way";
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

/** The real folder the shortcuts resolve to, which is what adoption moves. */
const SHARED = "/work/acme/.agents/skills/gh";

/** One tool's shortcut at that folder, as the scan read it — the shape
 *  `sharedLinkOf` looks the drift row up in. */
const linkedAt = (harness: DriftRow["harness"]): ObservedItem =>
  ({
    kind: "skill",
    name: "gh",
    harness,
    scope: ACME,
    path: `/work/acme/.${harness}/skills/gh`,
    fileState: { state: "symlink", target: SHARED, broken: false },
    enabled: true,
    origin: null,
    description: null,
    tags: [],
    modifiedAt: null,
    vendor: null,
  }) as unknown as ObservedItem;

const button = (host: HTMLElement, label: string) =>
  [...host.querySelectorAll("button")].find(
    (el) => el.textContent?.trim() === label,
  );

// The dialog renders into a portal, so it is off the page's own tree.
const dialog = () => {
  const el = document.body.querySelector('[role="dialog"]');
  expect(el).not.toBeNull();
  return el as HTMLElement;
};

const press = async (el: Element | undefined) => {
  expect(el).toBeDefined();
  await act(async () => {
    (el as HTMLButtonElement).click();
  });
};

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
  useScanStore.setState({ result: null });
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

// A folder somebody pointed several tools at is a bigger move than a plain
// folder: it goes whole, and shortcuts kendex cannot see break with it. So
// this button asks first, and every word of what it asks is read here —
// the two surfaces offering this move share their words, and only the
// Problems page's copy was covered.
describe("an item several tools read through shortcuts they set up", () => {
  it("asks before the move, naming the folder and every tool at it", async () => {
    stage([view([byHand("gh")])]);
    act(() => {
      useScanStore.setState({
        result: {
          harnesses: [],
          // Codex has no row of its own: it reads the same folder through
          // its own shortcut, and the move repoints it too.
          items: [linkedAt("claude"), linkedAt("codex")],
          missingProjects: [],
          warnings: [],
        } as never,
      });
    });
    const host = mount(<UnmanagedPage />);
    await settle();

    await press(button(host, START_MANAGING_LABEL));
    await settle();

    const said = dialog().textContent ?? "";
    expect(said).toContain(manageConfirmTitle("gh"));
    expect(said).toContain(manageSharedBody(SHARED, ["Claude Code", "Codex"]));
    const confirm = button(dialog(), PROCEED_LABEL);
    expect(confirm).toBeDefined();
    // The files move and nothing is deleted, so the confirm is not styled
    // as a deletion.
    expect(confirm?.className).not.toContain("bg-destructive");
  });
});
