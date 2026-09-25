// @vitest-environment jsdom
// The Settings way to the kendex command: one row per standing the backend
// can answer, and the install it keeps on offer after the first launch.
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CommandLink } from "@/bindings";
import { commands } from "@/bindings";
import { useCommandLinkStore } from "@/stores/command-link";
import { mount, settle } from "@/test/dom";
import { CommandLinkSection } from "./command-link-section";

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
const OLDER = "/Users/me/Downloads/kendex.app/Contents/MacOS/kendex";

const buttons = (host: HTMLElement) =>
  [...host.querySelectorAll("button")].map((b) => (b.textContent ?? "").trim());

beforeEach(() => {
  vi.mocked(commands.commandLinkState).mockReset();
  vi.mocked(commands.commandLinkInstall).mockReset();
  useCommandLinkStore.setState({
    state: null,
    readError: null,
    stage: { at: "idle" },
    question: null,
    answered: false,
  });
});

describe("the command row", () => {
  const rows: {
    name: string;
    command: CommandLink;
    drawn: boolean;
    buttons: string[];
    says: string;
  }[] = [
    {
      name: "is not drawn where the app carries no command",
      command: { kind: "notCarried" },
      drawn: false,
      buttons: [],
      says: "",
    },
    {
      name: "offers the install and names the link it creates",
      command: { kind: "offered", link: LINK, target: TARGET, replaces: null },
      drawn: true,
      buttons: ["Install"],
      says: `Creates a link at ${LINK} to the command inside this app, ${TARGET}`,
    },
    {
      name: "offers to point a link from an older copy here",
      command: { kind: "offered", link: LINK, target: TARGET, replaces: OLDER },
      drawn: true,
      buttons: ["Link to this app"],
      says: `${LINK} runs an older copy of kendex at ${OLDER}`,
    },
    {
      name: "says the link is installed",
      command: { kind: "linked", link: LINK, target: TARGET },
      drawn: true,
      buttons: [],
      says: `${LINK} runs the command inside this app.`,
    },
    {
      name: "names a command installed elsewhere",
      command: { kind: "elsewhere", path: "/opt/homebrew/bin/kendex" },
      drawn: true,
      buttons: [],
      says: "A kendex command is already installed at /opt/homebrew/bin/kendex.",
    },
    {
      name: "says a foreign file is left alone",
      command: { kind: "taken", link: LINK },
      drawn: true,
      buttons: [],
      says: `${LINK} is a file kendex did not create, so kendex leaves it alone.`,
    },
    {
      name: "says to move a translocated app to Applications",
      command: { kind: "translocated" },
      drawn: true,
      buttons: [],
      says: "Move kendex to your Applications folder",
    },
  ];
  it.each(rows)("$name", async (row) => {
    vi.mocked(commands.commandLinkState).mockResolvedValue({
      status: "ok",
      data: { command: row.command, ask: false },
    });
    const host = mount(<CommandLinkSection />);
    await settle();
    expect({
      drawn: host.textContent !== "",
      buttons: buttons(host),
      says: host.textContent?.includes(row.says),
    }).toEqual({ drawn: row.drawn, buttons: row.buttons, says: true });
  });

  it("says a failed read and offers to read again", async () => {
    vi.mocked(commands.commandLinkState).mockResolvedValue({
      status: "error",
      error: "settings.toml is not readable",
    });
    const host = mount(<CommandLinkSection />);
    await settle();
    const alert = host.querySelector('[role="alert"]');
    expect(alert?.textContent).toContain("settings.toml is not readable");
    expect(buttons(host)).toEqual(["Try again"]);
  });

  it("says a cancelled prompt on the row and keeps the install", async () => {
    vi.mocked(commands.commandLinkState).mockResolvedValue({
      status: "ok",
      data: {
        command: {
          kind: "offered",
          link: LINK,
          target: TARGET,
          replaces: null,
        },
        ask: false,
      },
    });
    vi.mocked(commands.commandLinkInstall).mockResolvedValue({
      status: "error",
      error: { kind: "cancelled" },
    });
    const host = mount(<CommandLinkSection />);
    await settle();
    await act(async () => {
      await userEvent.click(host.querySelector("button") as HTMLButtonElement);
    });
    await settle();
    expect(host.querySelector('[role="alert"]')?.textContent).toContain(
      "The administrator prompt was closed, so nothing was installed.",
    );
    expect(buttons(host)).toEqual(["Install"]);
  });
});
