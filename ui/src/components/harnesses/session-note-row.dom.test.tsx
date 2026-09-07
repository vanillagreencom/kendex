// @vitest-environment jsdom
import { act } from "react";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import {
  ADD_SESSION_NOTE_LABEL,
  addSessionNoteTitle,
  SESSION_NOTE_CHANGES,
  SESSION_NOTE_FAILED,
  SESSION_NOTE_OFF,
  SESSION_NOTE_ON,
  SESSION_NOTE_WAITING,
  SESSION_NOTE_WHAT,
  sessionNoteAdded,
  sessionNoteWaiting,
} from "@/lib/copy-session-note";
import { rescansSettled } from "@/lib/rescan";
import { useProblemsStore } from "@/stores/problems";
import { mount, settle } from "@/test/dom";
import { ProjectCard } from "./project-card";
import { SessionNoteRow } from "./session-note-row";

vi.mock("@/bindings", () => ({
  commands: {
    installDriftHook: vi.fn(),
    scanMachine: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    auditAll: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    commitOfferScan: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    getSettings: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const ROOT = "/work/acme";

const button = (host: HTMLElement | Document, label: string) =>
  [...host.querySelectorAll("button")].find(
    (el) => el.textContent?.trim() === label,
  );

const row = (state: "off" | "waiting" | "on") =>
  mount(<SessionNoteRow name="acme" root={ROOT} state={state} />);

/** Press the card's button, then the dialog's. */
const sayYes = async (host: HTMLElement) => {
  await act(async () => button(host, ADD_SESSION_NOTE_LABEL)?.click());
  await settle();
  // The dialog is in a portal, off the row's own tree; the card's button
  // is gone from under it only in the ordinary sense — both carry the
  // same words, so the confirm is the one outside the host.
  const confirm = [...document.body.querySelectorAll("button")].find(
    (el) =>
      el.textContent?.trim() === ADD_SESSION_NOTE_LABEL && !host.contains(el),
  );
  if (!confirm) throw new Error("the dialog offered no confirm");
  await act(async () => confirm.click());
  await settle();
  await rescansSettled();
};

beforeEach(() => {
  vi.clearAllMocks();
  useProblemsStore.getState().closeError();
});

describe("the start-of-session note on a project's card", () => {
  it("says what agents here get in each state, with a button only while off", () => {
    expect(row("off").textContent).toContain(SESSION_NOTE_OFF);
    expect(button(row("off"), ADD_SESSION_NOTE_LABEL)).toBeDefined();

    const on = row("on");
    expect(on.textContent).toContain(SESSION_NOTE_ON);
    expect(button(on, ADD_SESSION_NOTE_LABEL)).toBeUndefined();

    const waiting = row("waiting");
    expect(waiting.textContent).toContain(SESSION_NOTE_WAITING);
    expect(button(waiting, ADD_SESSION_NOTE_LABEL)).toBeUndefined();
  });

  // What it is and what changes on disk are said before the ask, in the
  // dialog the button opens — not in a toast that vanishes.
  it("says what the note is and what changes before asking", async () => {
    const host = row("off");
    await act(async () => button(host, ADD_SESSION_NOTE_LABEL)?.click());
    await settle();
    const text = document.body.textContent ?? "";
    expect(text).toContain(addSessionNoteTitle("acme"));
    expect(text).toContain(SESSION_NOTE_WHAT);
    expect(text).toContain(SESSION_NOTE_CHANGES);
    expect(commands.installDriftHook).not.toHaveBeenCalled();
  });

  it("installs at this project on yes and says the note was added", async () => {
    vi.mocked(commands.installDriftHook).mockResolvedValue({
      status: "ok",
      data: true,
    });
    await sayYes(row("off"));
    expect(commands.installDriftHook).toHaveBeenCalledWith({
      scope: "project",
      root: ROOT,
    });
    expect(toast.success).toHaveBeenCalledWith(sessionNoteAdded("acme"));
  });

  // False: the scope had other pending changes, so only the declaration
  // landed. The words are the waiting state's, not a success.
  it("says the note is set up but not in place when only the declaration landed", async () => {
    vi.mocked(commands.installDriftHook).mockResolvedValue({
      status: "ok",
      data: false,
    });
    await sayYes(row("off"));
    expect(toast.success).toHaveBeenCalledWith(sessionNoteWaiting("acme"));
    expect(toast.success).not.toHaveBeenCalledWith(sessionNoteAdded("acme"));
  });

  // The card opens the Library on a click in its empty space, and React
  // sends a portal's clicks back through the tree that owns it: reading
  // the dialog, or pressing its backdrop to close it, must not be a
  // request to leave the page.
  it("does not open the card behind it from a click in the dialog", async () => {
    const onOpen = vi.fn();
    const host = mount(
      <ProjectCard
        name="acme"
        subtitle={ROOT}
        path={ROOT}
        counts={[]}
        emptyLabel="Nothing from kendex yet."
        onOpen={onOpen}
        onKindClick={() => {}}
        note={<SessionNoteRow name="acme" root={ROOT} state="off" />}
      />,
    );
    await act(async () => button(host, ADD_SESSION_NOTE_LABEL)?.click());
    await settle();
    for (const slot of ["dialog-title", "dialog-content", "dialog-overlay"]) {
      const target = document.body.querySelector<HTMLElement>(
        `[data-slot="${slot}"]`,
      );
      if (!target) throw new Error(`no ${slot} on screen`);
      await act(async () => target.click());
    }
    expect(onOpen).not.toHaveBeenCalled();
  });

  it("puts a refusal in the problems dialog under the note's own title", async () => {
    vi.mocked(commands.installDriftHook).mockResolvedValue({
      status: "error",
      error: "the hook folder is read-only",
    });
    await sayYes(row("off"));
    expect(toast.success).not.toHaveBeenCalled();
    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe(SESSION_NOTE_FAILED);
    expect(dialog.message).toBe("the hook folder is read-only");
  });
});
