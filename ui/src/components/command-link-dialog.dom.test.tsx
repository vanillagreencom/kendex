// @vitest-environment jsdom
// The macOS app's first-launch question, over every state it can draw.
// Whether to ask is the backend's `ask`; what an install does is the
// backend's answer too, so each case hands the dialog one reply and reads
// what is on screen and what was recorded.
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CommandLinkState, LinkRefused } from "@/bindings";
import { commands } from "@/bindings";
import { useCommandLinkStore } from "@/stores/command-link";
import { useTermsStore } from "@/stores/terms";
import { mount, settle } from "@/test/dom";
import { CommandLinkDialog } from "./command-link-dialog";

vi.mock("@/bindings", () => ({
  commands: {
    commandLinkState: vi.fn(),
    commandLinkInstall: vi.fn(),
    commandLinkPromptAnswered: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn() } }));

const LINK = "/usr/local/bin/kendex";
const TARGET = "/Applications/kendex.app/Contents/MacOS/kendex";

const asking: CommandLinkState = {
  command: { kind: "offered", link: LINK, target: TARGET, replaces: null },
  ask: true,
};
const linked: CommandLinkState = {
  command: { kind: "linked", link: LINK, target: TARGET },
  ask: false,
};
const answered: CommandLinkState = { ...asking, ask: false };

const dialog = () => document.querySelector('[role="dialog"]');
const button = (label: string) =>
  [...document.querySelectorAll("button")].find(
    (b) => (b.textContent ?? "").trim() === label,
  ) as HTMLButtonElement | undefined;
const press = async (label: string) => {
  const target = button(label);
  expect(target, `button ${label}`).toBeDefined();
  await act(async () => {
    await userEvent.click(target as HTMLButtonElement);
  });
};

beforeEach(() => {
  vi.mocked(commands.commandLinkState).mockReset();
  vi.mocked(commands.commandLinkInstall).mockReset();
  vi.mocked(commands.commandLinkPromptAnswered).mockReset();
  vi.mocked(commands.commandLinkPromptAnswered).mockResolvedValue({
    status: "ok",
    data: answered,
  });
  useCommandLinkStore.setState({
    state: null,
    readError: null,
    stage: { at: "idle" },
    question: null,
    answered: false,
  });
  useTermsStore.setState({
    state: { ask: false, accepted: null },
    error: null,
  });
});

describe("whether the first launch asks", () => {
  const rows: {
    name: string;
    read: CommandLinkState;
    termsAsk: boolean;
    asks: boolean;
  }[] = [
    {
      name: "asks when the backend says to",
      read: asking,
      termsAsk: false,
      asks: true,
    },
    {
      name: "asks nothing once answered",
      read: answered,
      termsAsk: false,
      asks: false,
    },
    {
      name: "asks nothing when installed",
      read: linked,
      termsAsk: false,
      asks: false,
    },
    {
      name: "waits behind the terms screen",
      read: asking,
      termsAsk: true,
      asks: false,
    },
  ];
  it.each(rows)("$name", async (row) => {
    vi.mocked(commands.commandLinkState).mockResolvedValue({
      status: "ok",
      data: row.read,
    });
    useTermsStore.setState({
      state: { ask: row.termsAsk, accepted: null },
      error: null,
    });
    mount(<CommandLinkDialog />);
    await settle();
    expect(dialog() !== null).toBe(row.asks);
  });

  it("states the link it creates and what it points at", async () => {
    vi.mocked(commands.commandLinkState).mockResolvedValue({
      status: "ok",
      data: asking,
    });
    mount(<CommandLinkDialog />);
    await settle();
    expect(dialog()?.textContent).toContain(LINK);
    expect(dialog()?.textContent).toContain(TARGET);
  });
});

describe("an answer", () => {
  it("declining records the answer and closes", async () => {
    vi.mocked(commands.commandLinkState).mockResolvedValue({
      status: "ok",
      data: asking,
    });
    mount(<CommandLinkDialog />);
    await settle();
    await press("Don't install");
    await settle();
    expect(commands.commandLinkPromptAnswered).toHaveBeenCalledTimes(1);
    expect(commands.commandLinkInstall).not.toHaveBeenCalled();
    expect(dialog()).toBeNull();
  });

  it("holds both buttons while the administrator prompt is up", async () => {
    vi.mocked(commands.commandLinkState).mockResolvedValue({
      status: "ok",
      data: asking,
    });
    let finish: (value: { status: "ok"; data: CommandLinkState }) => void =
      () => {};
    vi.mocked(commands.commandLinkInstall).mockReturnValue(
      new Promise((resolve) => {
        finish = resolve;
      }),
    );
    mount(<CommandLinkDialog />);
    await settle();
    await press("Install");
    expect(button("Installing…")?.disabled).toBe(true);
    expect(button("Don't install")?.disabled).toBe(true);
    expect(dialog()?.textContent).toContain("administrator password");
    await act(async () => finish({ status: "ok", data: linked }));
  });

  // Each ending of an install, as the backend answers it: the title, the
  // buttons left to press, and the line naming the cause.
  const endings: {
    name: string;
    reply:
      | { status: "ok"; data: CommandLinkState }
      | { status: "error"; error: LinkRefused | string };
    buttons: string[];
    says: string;
  }[] = [
    {
      name: "installed",
      reply: { status: "ok", data: linked },
      buttons: ["Done"],
      says: `${LINK} now runs the command inside this app`,
    },
    {
      name: "cancelled at the administrator prompt",
      reply: { status: "error", error: { kind: "cancelled" } },
      buttons: ["Don't install", "Try again"],
      says: "The administrator prompt was closed, so nothing was installed.",
    },
    {
      name: "refused by a file kendex did not create",
      reply: {
        status: "error",
        error: { kind: "notOffered", command: { kind: "taken", link: LINK } },
      },
      buttons: ["Close"],
      says: `${LINK} is a file kendex did not create, so kendex leaves it alone.`,
    },
    {
      name: "failed in the step",
      reply: {
        status: "error",
        error: { kind: "failed", message: "ln: Read-only file system" },
      },
      buttons: ["Don't install", "Try again"],
      says: "Nothing was installed: ln: Read-only file system",
    },
    {
      name: "failed in the transport",
      reply: { status: "error", error: "the bridge closed" },
      buttons: ["Don't install", "Try again"],
      says: "Nothing was installed: the bridge closed",
    },
  ];
  it.each(endings)("$name", async (row) => {
    vi.mocked(commands.commandLinkState).mockResolvedValue({
      status: "ok",
      data: asking,
    });
    vi.mocked(commands.commandLinkInstall).mockResolvedValue(row.reply);
    mount(<CommandLinkDialog />);
    await settle();
    await press("Install");
    await settle();
    const footer = [
      ...(dialog()?.querySelectorAll('[data-slot="dialog-footer"] button') ??
        []),
    ].map((b) => (b.textContent ?? "").trim());
    expect({
      buttons: footer,
      says: dialog()?.textContent?.includes(row.says),
      answered: vi.mocked(commands.commandLinkPromptAnswered).mock.calls.length,
    }).toEqual({ buttons: row.buttons, says: true, answered: 0 });
  });
});
