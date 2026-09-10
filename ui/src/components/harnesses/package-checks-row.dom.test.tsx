// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act, useState } from "react";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { PlannedFile, SetupPlan } from "@/bindings";
import { commands } from "@/bindings";
import {
  CHECKS_BLOCKED_NOTE,
  CHECKS_CONFLICTS_NOTE,
  CHECKS_QUIET,
  CHECKS_REMOVE,
  CHECKS_WHAT,
  CHECKS_WHEN,
  checksHeld,
  checksOn,
  ENABLE_CHECKS_LABEL,
  ENABLE_FAILED,
  enableChecksTitle,
  FILES_DISCLOSURE_LABEL,
  heldBecause,
  NO_PREVIEW_WORDS,
  notRunningIn,
  otherChangesWaiting,
  PACKAGE_CHECKS_HELP_LABEL,
  PACKAGE_CHECKS_LIBRARY_LABEL,
  roleMeans,
  runsIn,
} from "@/lib/copy-package-checks";
import type { ChecksStanding } from "@/lib/package-checks";
import { rescansSettled } from "@/lib/rescan";
import { useProblemsStore } from "@/stores/problems";
import { mount, settle } from "@/test/dom";
import { PackageChecksRow } from "./package-checks-row";

vi.mock("@/bindings", () => ({
  PACKAGE_CHECK_HARNESSES: ["claude", "pi"] as const,
  commands: {
    packageCheckPlan: vi.fn(),
    enablePackageChecks: vi.fn(),
    scanMachine: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    auditAll: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    commitOfferScan: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    getSettings: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const ROOT = "/work/acme";

const file = (over: Partial<PlannedFile>): PlannedFile => ({
  path: ".agents/kendex/hooks/kendex-drift.sh",
  change: "add",
  role: "check-script",
  harness: null,
  preview: "#!/bin/sh\n",
  noPreview: null,
  ...over,
});

const plan = (over: Partial<SetupPlan> = {}): SetupPlan => ({
  harnesses: ["claude", "pi"],
  files: [
    file({}),
    file({
      path: ".claude/settings.json",
      change: "change",
      role: "startup-registration",
      harness: "claude",
      preview: null,
      noPreview: "shared-file",
    }),
  ],
  otherPending: 0,
  conflicts: [],
  blocked: [],
  ...over,
});

const standing = (over: Partial<ChecksStanding> = {}): ChecksStanding => ({
  state: "off",
  running: [],
  waiting: ["claude", "pi"],
  ...over,
});

const openLibrary = vi.fn();

/** A row whose standing the test can change, the way a rescan changes it
 *  under a mounted card. */
const drivenRow = () => {
  let drive: ((next: ChecksStanding) => void) | null = null;
  function Driven() {
    const [current, set] = useState<ChecksStanding>(standing());
    drive = set;
    return (
      <PackageChecksRow
        name="acme"
        root={ROOT}
        standing={current}
        harnesses={["claude", "pi"]}
        folderMissing={false}
        onOpenLibrary={openLibrary}
      />
    );
  }
  const host = mount(<Driven />);
  const rescan = async (next: Partial<ChecksStanding>) => {
    if (!drive) throw new Error("the row never mounted");
    const set = drive;
    await act(async () => set(standing(next)));
    await settle();
  };
  return { host, rescan };
};

const row = (over: Partial<ChecksStanding> = {}) =>
  mount(
    <PackageChecksRow
      name="acme"
      root={ROOT}
      standing={standing(over)}
      harnesses={["claude", "pi"]}
      folderMissing={false}
      onOpenLibrary={openLibrary}
    />,
  );

const button = (host: HTMLElement | Document, label: string) =>
  [...host.querySelectorAll("button")].find(
    (el) => el.textContent?.trim() === label,
  );

const inDialog = (label: string) =>
  [...document.body.querySelectorAll("button")].find(
    (el) =>
      el.textContent?.trim() === label &&
      el.closest('[data-slot="dialog-content"]') !== null,
  );

/** Press Enable checks and let the confirmation's plan read land. */
const ask = async (host: HTMLElement) => {
  await act(async () => button(host, ENABLE_CHECKS_LABEL)?.click());
  await settle();
};

const confirm = async () => {
  const press = inDialog(ENABLE_CHECKS_LABEL);
  if (!press) throw new Error("the dialog offered no confirm");
  await act(async () => press.click());
  await settle();
  await rescansSettled();
};

beforeEach(() => {
  vi.clearAllMocks();
  useProblemsStore.getState().closeError();
  vi.mocked(commands.packageCheckPlan).mockResolvedValue({
    status: "ok",
    data: plan(),
  });
});

describe("the help beside the package checks label", () => {
  // One panel, reached the same way by either kind of user: a hover-only
  // explanation is no explanation for a keyboard.
  it("opens on a pointer and on a keyboard, and writes nothing", async () => {
    for (const how of ["pointer", "keyboard"] as const) {
      const host = row();
      const info = [...host.querySelectorAll("button")].find(
        (el) => el.getAttribute("aria-label") === PACKAGE_CHECKS_HELP_LABEL,
      );
      if (!info) throw new Error("no help button on the row");
      if (how === "pointer") {
        await act(async () => info.click());
      } else {
        act(() => info.focus());
        await userEvent.keyboard("{Enter}");
      }
      await settle();
      const text = document.body.textContent ?? "";
      expect(text, how).toContain(CHECKS_WHAT);
      expect(text, how).toContain(CHECKS_WHEN);
      expect(text, how).toContain(CHECKS_QUIET);
      expect(text, how).toContain(CHECKS_REMOVE);
      expect(commands.packageCheckPlan, how).not.toHaveBeenCalled();
      expect(commands.enablePackageChecks, how).not.toHaveBeenCalled();
      // Closed the way a reader closes it, so the next pass reads its own
      // panel rather than the one left standing.
      await userEvent.keyboard("{Escape}");
      await settle();
      expect(host.textContent, how).not.toContain(CHECKS_WHAT);
    }
  });
});

describe("the package checks confirmation", () => {
  it("names the project and reads the plan without writing", async () => {
    await ask(row());
    expect(document.body.textContent).toContain(enableChecksTitle("acme"));
    expect(commands.packageCheckPlan).toHaveBeenCalledWith({
      scope: "project",
      root: ROOT,
    });
    expect(commands.enablePackageChecks).not.toHaveBeenCalled();
  });

  // The disclosure is the plan's own rows: every path it will write, its
  // add/change word, its role, and — where kendex holds no content before
  // the write — the reason there is none.
  it("discloses the files the plan names, with the reason a row has no preview", async () => {
    const host = row();
    await ask(host);
    await act(async () => inDialog(`${FILES_DISCLOSURE_LABEL} (2)`)?.click());
    await settle();
    const text = document.body.textContent ?? "";
    for (const one of plan().files) {
      expect(text, one.path).toContain(one.path.split("/").pop());
    }
    expect(text).toContain(roleMeans("check-script", null));
    const registration = [...document.body.querySelectorAll("button")].find(
      (el) => el.getAttribute("title") === ".claude/settings.json",
    );
    if (!registration) throw new Error("the tree listed no registration row");
    await act(async () => registration.click());
    await settle();
    expect(document.body.textContent).toContain(
      NO_PREVIEW_WORDS["shared-file"],
    );
    expect(commands.enablePackageChecks).not.toHaveBeenCalled();
  });

  it("leaves the project alone on Cancel", async () => {
    const host = row();
    await ask(host);
    const cancel = inDialog("Cancel");
    if (!cancel) throw new Error("the dialog offered no cancel");
    await act(async () => cancel.click());
    await settle();
    expect(commands.enablePackageChecks).not.toHaveBeenCalled();
  });

  // A yes to the checks is not a yes to whatever else is waiting, so the
  // ask says what enabling now writes and what it leaves for later.
  it("says what is waiting here before the ask", async () => {
    vi.mocked(commands.packageCheckPlan).mockResolvedValue({
      status: "ok",
      data: plan({ otherPending: 3 }),
    });
    await ask(row());
    expect(document.body.textContent).toContain(otherChangesWaiting(3));
  });

  // Two facts, each on its own evidence. An unsettled position holds up
  // its own item; waiting changes hold up the registration. A scope with
  // both says both, and one with only an unsettled position says nothing
  // about the registration waiting — because it does not.
  it("keeps unsettled positions and waiting changes apart", async () => {
    vi.mocked(commands.packageCheckPlan).mockResolvedValue({
      status: "ok",
      data: plan({
        otherPending: 2,
        conflicts: ["/work/acme/.claude/skills/deploy"],
      }),
    });
    await ask(row());
    const both = document.body.textContent ?? "";
    expect(both).toContain(CHECKS_CONFLICTS_NOTE);
    expect(both).toContain("/work/acme/.claude/skills/deploy");
    expect(both).toContain(otherChangesWaiting(2));

    // Closed the way a reader closes it, so the next pass reads its own
    // dialog rather than the one left standing.
    await userEvent.keyboard("{Escape}");
    await settle();
    vi.mocked(commands.packageCheckPlan).mockResolvedValue({
      status: "ok",
      data: plan({
        otherPending: 0,
        conflicts: ["/work/acme/.claude/skills/deploy"],
      }),
    });
    await ask(row());
    const alone = document.body.textContent ?? "";
    expect(alone).toContain(CHECKS_CONFLICTS_NOTE);
    expect(alone).not.toContain(otherChangesWaiting(0));
    expect(alone).not.toContain("goes in when those changes do");
  });

  // A position at the check's OWN destination does stop the registration,
  // unlike one anywhere else in the project. The two sentences must stay
  // distinguishable or one of them is false.
  it("says a position at the check's own target stops it", async () => {
    vi.mocked(commands.packageCheckPlan).mockResolvedValue({
      status: "ok",
      data: plan({ blocked: ["/work/acme/.claude/settings.json"] }),
    });
    await ask(row());
    const text = document.body.textContent ?? "";
    expect(text).toContain(CHECKS_BLOCKED_NOTE);
    expect(text).toContain("/work/acme/.claude/settings.json");
    expect(text).not.toContain(CHECKS_CONFLICTS_NOTE);
  });

  it("offers nothing over a plan it could not read", async () => {
    vi.mocked(commands.packageCheckPlan).mockResolvedValue({
      status: "error",
      error: "the folder is not there",
    });
    await ask(row());
    expect(inDialog(ENABLE_CHECKS_LABEL)?.disabled).toBe(true);
  });
});

describe("what the confirmation reports", () => {
  it("says the checks are on when every tool is registered", async () => {
    vi.mocked(commands.enablePackageChecks).mockResolvedValue({
      status: "ok",
      data: { complete: true, held: null },
    });
    await ask(row());
    await confirm();
    expect(commands.enablePackageChecks).toHaveBeenCalledWith({
      scope: "project",
      root: ROOT,
    });
    expect(toast.success).toHaveBeenCalledWith(checksOn("acme"));
  });

  // The command read the scope back and found the registration missing:
  // the words are the incomplete state's, never a success.
  it("says the setup is not running yet when a tool is still waiting", async () => {
    vi.mocked(commands.enablePackageChecks).mockResolvedValue({
      status: "ok",
      data: {
        complete: false,
        held: { kind: "otherChanges", count: 2 },
      },
    });
    const host = row();
    await ask(host);
    await confirm();
    expect(toast.success).toHaveBeenCalledWith(checksHeld("acme"));
    expect(toast.success).not.toHaveBeenCalledWith(checksOn("acme"));
    // The scan that follows says which tools are covered; only the write
    // knows why the rest are waiting, so that reason stays on the row.
    expect(host.textContent).toContain(
      heldBecause({ kind: "otherChanges", count: 2 }),
    );
  });

  // An incomplete setup always has a reason now, because complete is the
  // absence of one. This is the answer of last resort.
  it("says which tools are waiting when nothing else explains it", async () => {
    vi.mocked(commands.enablePackageChecks).mockResolvedValue({
      status: "ok",
      data: {
        complete: false,
        held: { kind: "notRegistered", harnesses: ["pi"] },
      },
    });
    const host = row();
    await ask(host);
    await confirm();
    expect(toast.success).toHaveBeenCalledWith(checksHeld("acme"));
    expect(host.textContent).toContain(
      heldBecause({ kind: "notRegistered", harnesses: ["pi"] }),
    );
  });

  it("puts a refusal in the problems dialog under the feature's own title", async () => {
    vi.mocked(commands.enablePackageChecks).mockResolvedValue({
      status: "error",
      error: "/work/acme is not there",
    });
    await ask(row());
    await confirm();
    expect(toast.success).not.toHaveBeenCalled();
    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe(ENABLE_FAILED);
    expect(dialog.message).toBe("/work/acme is not there");
  });
});

describe("a reason the row was given", () => {
  // The reason belongs to the setup it was given about. Once a rescan
  // finds the checks running, that setup is over: a later rescan finding
  // them incomplete again is a different state, and the old reason does
  // not explain it.
  it("does not come back after the checks have reached on", async () => {
    vi.mocked(commands.enablePackageChecks).mockResolvedValue({
      status: "ok",
      data: { complete: false, held: { kind: "otherChanges", count: 2 } },
    });
    const { host, rescan } = drivenRow();
    await ask(host);
    await confirm();
    const reason = heldBecause({ kind: "otherChanges", count: 2 });
    expect(host.textContent).toContain(reason);

    await rescan({ state: "on", running: ["claude", "pi"], waiting: [] });
    expect(host.textContent).not.toContain(reason);

    // An external apply finished the setup and a registration went away
    // after it: incomplete again, with nothing here that explains why.
    await rescan({ state: "incomplete", running: ["claude"], waiting: ["pi"] });
    expect(host.textContent).not.toContain(reason);
  });
});

describe("a project whose checks are already set up", () => {
  // Nothing to enable, and a route to where it is turned off, removed, or
  // seen beside whatever else is waiting here.
  it("offers the Library instead of an install", () => {
    for (const state of ["on", "incomplete"] as const) {
      const host = row({ state, running: ["claude"], waiting: ["pi"] });
      expect(button(host, ENABLE_CHECKS_LABEL), state).toBeUndefined();
      // Partial coverage is read per tool, and the incomplete state is
      // where both halves are said: the state's own sentence stands in
      // front of them and has to hold beside them.
      expect(host.textContent, state).toContain(runsIn(["claude"]));
      if (state === "incomplete") {
        expect(host.textContent, state).toContain(notRunningIn(["pi"]));
      }
      const open = button(host, PACKAGE_CHECKS_LIBRARY_LABEL);
      if (!open) throw new Error(`no Library route in ${state}`);
      act(() => open.click());
      expect(openLibrary, state).toHaveBeenCalled();
      openLibrary.mockClear();
    }
  });
});
