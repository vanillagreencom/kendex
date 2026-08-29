// @vitest-environment jsdom
// The out-of-date card is one read and three offers. What these tests hold
// to is that it never says more than the check found: nothing at all when
// the check failed or the release is hidden, and only the action the
// running install's channel can carry out.
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppUpdateView, InstallChannel } from "@/bindings";
import { commands } from "@/bindings";
import {
  APP_UPDATE_COMMAND_UNKNOWN_NOTE,
  APP_UPDATE_DISMISS_LABEL,
  APP_UPDATE_INSTALL_LABEL,
  APP_UPDATE_INSTALLING_LABEL,
  APP_UPDATE_NOTES_LABEL,
  APP_UPDATE_TITLE,
  APP_UPDATE_UNKNOWN_NOTE,
  appUpdateCommandManagedNote,
} from "@/lib/copy";
import { useNoticeStore } from "@/stores/notice";
import { mount, settle } from "@/test/dom";
import { SidebarNotice } from "./sidebar-notice";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    appVersion: vi.fn(),
    appUpdateCheck: vi.fn(),
    appUpdateChannel: vi.fn(),
    appUpdateCommandChannel: vi.fn(),
    appUpdateInstall: vi.fn(),
    getSettings: vi.fn(),
    updateSettings: vi.fn(),
    openUrl: vi.fn(),
  },
}));

const RUNNING = "5.0.1";
const RELEASED = "5.1.0";
const NOTES = `https://github.com/vanillagreencom/kendex/releases/tag/v${RELEASED}`;

const view = (
  status: AppUpdateView["status"],
): { status: "ok"; data: AppUpdateView } => ({
  status: "ok",
  data: {
    automaticCheckEnabled: true,
    status,
    lastAttemptAt: null,
    lastSuccessAt: null,
    servedFeedAt: null,
    servedFeedAgeSecs: null,
    servedFeedInFuture: false,
    lastError: null,
  },
});

const available = (muted = false): { status: "ok"; data: AppUpdateView } =>
  view({
    kind: "updateAvailable",
    version: RELEASED,
    releaseNotesUrl: NOTES,
    cliAssetAvailable: true,
    muted,
  });

/** Load the store as the startup fan-out does, then put the card on screen. */
async function show(
  channel: InstallChannel = { kind: "direct" },
  commandChannel: InstallChannel | null = null,
) {
  vi.mocked(commands.appUpdateChannel).mockResolvedValue({
    status: "ok",
    data: channel,
  });
  vi.mocked(commands.appUpdateCommandChannel).mockResolvedValue({
    status: "ok",
    data: commandChannel,
  });
  await useNoticeStore.getState().load();
  const container = mount(<SidebarNotice />);
  await settle();
  return container;
}

const offer = (container: HTMLElement, label: string): HTMLButtonElement => {
  const button = [...container.querySelectorAll("button")].find(
    (node) =>
      node.textContent === label || node.getAttribute("aria-label") === label,
  );
  if (!button) throw new Error(`no "${label}" button on the card`);
  return button;
};

const press = async (container: HTMLElement, label: string) => {
  await userEvent.click(offer(container, label));
  await settle();
};

beforeEach(() => {
  vi.clearAllMocks();
  useNoticeStore.setState({
    notice: null,
    channel: { kind: "unknown" },
    installing: false,
    error: null,
  });
  vi.mocked(commands.appVersion).mockResolvedValue(RUNNING);
  vi.mocked(commands.appUpdateCheck).mockResolvedValue(available());
  vi.mocked(commands.getSettings).mockResolvedValue({
    status: "ok",
    data: { settings: { schema: 1, appearance: "system" }, base: "abc" },
  });
  vi.mocked(commands.openUrl).mockResolvedValue({ status: "ok", data: null });
  vi.mocked(commands.updateSettings).mockResolvedValue({
    status: "ok",
    data: { settings: { schema: 1, appearance: "system" }, base: "def" },
  });
});

describe("what the card says", () => {
  it("names both versions once a release is out", async () => {
    const container = await show();
    expect(container.textContent).toContain(APP_UPDATE_TITLE);
    expect(container.textContent).toContain(RELEASED);
    expect(container.textContent).toContain(RUNNING);
    // The release notes are the one offer every channel carries, and the
    // link is the release's own: an app that cannot replace itself still
    // has to be able to send the person to what changed.
    await press(container, APP_UPDATE_NOTES_LABEL);
    expect(commands.openUrl).toHaveBeenCalledWith(NOTES);
  });

  it("stays away while this build is the latest", async () => {
    vi.mocked(commands.appUpdateCheck).mockResolvedValue(
      view({ kind: "upToDate", version: RUNNING }),
    );
    expect((await show()).textContent).toBe("");
  });

  // A card claims a named release is out. A check that did not land is no
  // evidence of one, and the surface that reports on checking owns the
  // error.
  it("stays away when the check itself failed", async () => {
    vi.mocked(commands.appUpdateCheck).mockResolvedValue({
      status: "error",
      error: "no network",
    });
    expect((await show()).textContent).toBe("");
  });

  it("stays away while this version is hidden", async () => {
    vi.mocked(commands.appUpdateCheck).mockResolvedValue(available(true));
    expect((await show()).textContent).toBe("");
  });
});

describe("the action each channel allows", () => {
  // In flight is the last state this offer has: the real command does not
  // come back when it works, the app restarts into the new version. So the
  // replacement is held open here and the card read while it runs.
  it("offers the replacement where kendex owns the files", async () => {
    let finish = () => {};
    vi.mocked(commands.appUpdateInstall).mockReturnValue(
      new Promise((resolve) => {
        finish = () => resolve({ status: "ok", data: null });
      }),
    );
    const container = await show({ kind: "direct" });
    expect(container.textContent).toContain(APP_UPDATE_INSTALL_LABEL);
    await press(container, APP_UPDATE_INSTALL_LABEL);
    expect(commands.appUpdateInstall).toHaveBeenCalledTimes(1);

    // Running: the card says so, nothing has failed, and the offer cannot
    // be taken a second time — by the button, and by the store behind it,
    // which is what a keyboard or a second window would reach.
    expect(container.textContent).toContain(APP_UPDATE_INSTALLING_LABEL);
    expect(useNoticeStore.getState().error).toBeNull();
    expect(offer(container, APP_UPDATE_INSTALLING_LABEL).disabled).toBe(true);
    await act(async () => {
      await useNoticeStore.getState().install();
    });
    expect(commands.appUpdateInstall).toHaveBeenCalledTimes(1);

    finish();
    await settle();
  });

  it("shows a package manager's command and offers no replacement", async () => {
    const container = await show({
      kind: "managed",
      manager: "an AUR helper",
      command: "paru -S kendex-bin",
    });
    expect(container.textContent).toContain("paru -S kendex-bin");
    expect(container.textContent).not.toContain(APP_UPDATE_INSTALL_LABEL);
  });

  it("offers nothing to press where nothing could tell", async () => {
    const container = await show({ kind: "unknown" });
    expect(container.textContent).toContain(APP_UPDATE_UNKNOWN_NOTE);
    expect(container.textContent).not.toContain(APP_UPDATE_INSTALL_LABEL);
  });

  // Update now replaces the app and restarts into it, so anything the
  // person needs to know about the command it leaves behind has to be on
  // the card before the button is pressed. Afterwards there is no card.
  it("names the installer that owns the command, and how to move it", async () => {
    const container = await show(
      { kind: "direct" },
      {
        kind: "managed",
        manager: "Homebrew",
        command: "brew upgrade kendex-cli",
      },
    );
    expect(container.textContent).toContain(APP_UPDATE_INSTALL_LABEL);
    expect(container.textContent).toContain(
      appUpdateCommandManagedNote("Homebrew"),
    );
    expect(container.textContent).toContain("brew upgrade kendex-cli");
  });

  // The name comes from the channel, so a different installer reads as
  // itself rather than as whatever the first case happened to be.
  it("names whichever installer the channel carries", async () => {
    const container = await show(
      { kind: "direct" },
      {
        kind: "managed",
        manager: "an AUR helper",
        command: "paru -S kendex",
      },
    );
    expect(container.textContent).toContain(
      appUpdateCommandManagedNote("an AUR helper"),
    );
    expect(container.textContent).not.toContain("Homebrew");
  });

  // Nothing kendex could name owns it, so the card says the command is
  // left behind and stops there rather than inventing a way to move it.
  it("names no installer where nothing could tell who owns it", async () => {
    const container = await show({ kind: "direct" }, { kind: "unknown" });
    expect(container.textContent).toContain(APP_UPDATE_COMMAND_UNKNOWN_NOTE);
    // No half-written sentence, and no invented owner.
    expect(container.textContent).not.toContain("installed by");
    expect(container.textContent).not.toContain("update it with:");
  });

  // The two cases with nothing to say: no command beside the app, and one
  // Update now will carry across itself.
  it("says nothing about the command where it is not left behind", async () => {
    const container = await show({ kind: "direct" }, null);
    expect(container.textContent).toContain(APP_UPDATE_INSTALL_LABEL);
    expect(container.textContent).not.toContain("updates the app only");
  });

  // A channel read that failed is the same offer as one nothing
  // recognised: never a replacement built on a guess.
  it("falls back to no action when the channel could not be read", async () => {
    vi.mocked(commands.appUpdateChannel).mockResolvedValue({
      status: "error",
      error: "the running app's own path is unreadable",
    });
    vi.mocked(commands.appUpdateCommandChannel).mockResolvedValue({
      status: "ok",
      data: null,
    });
    await useNoticeStore.getState().load();
    const container = mount(<SidebarNotice />);
    await settle();
    expect(container.textContent).toContain(APP_UPDATE_UNKNOWN_NOTE);
    expect(container.textContent).not.toContain(APP_UPDATE_INSTALL_LABEL);
  });
});

describe("a replacement that did not happen", () => {
  it("says why on the card and leaves the action to try again", async () => {
    vi.mocked(commands.appUpdateInstall).mockResolvedValue({
      status: "error",
      error: "the release could not be verified",
    });
    const container = await show();
    await press(container, APP_UPDATE_INSTALL_LABEL);
    expect(container.textContent).toContain(
      "the release could not be verified",
    );
    expect(container.textContent).toContain(APP_UPDATE_INSTALL_LABEL);
  });

  // Hiding the card mid-replacement would take away the only thing that
  // reports the failure, and the mute is keyed to this version, so the
  // release would never offer itself again: the person would be left on
  // the old build believing they had updated.
  it("cannot be hidden while the replacement is running", async () => {
    let fail = () => {};
    vi.mocked(commands.appUpdateInstall).mockReturnValue(
      new Promise((resolve) => {
        fail = () =>
          resolve({
            status: "error",
            error: "the release could not be verified",
          });
      }),
    );
    const container = await show({ kind: "direct" });
    await press(container, APP_UPDATE_INSTALL_LABEL);

    expect(offer(container, APP_UPDATE_DISMISS_LABEL).disabled).toBe(true);
    // And the store refuses it too, so nothing reaching past the button —
    // another surface, a keyboard, a second window — can mute the version
    // the replacement is still working on.
    await act(async () => {
      await useNoticeStore.getState().dismiss();
    });
    expect(commands.updateSettings).not.toHaveBeenCalled();

    fail();
    await settle();
    expect(container.textContent).toContain(APP_UPDATE_TITLE);
    expect(container.textContent).toContain(
      "the release could not be verified",
    );
  });
});

describe("hiding this version", () => {
  it("writes the version it is showing, and takes the card away", async () => {
    const container = await show();
    await press(container, APP_UPDATE_DISMISS_LABEL);
    expect(commands.updateSettings).toHaveBeenCalledWith(
      expect.objectContaining({ "muted-app-notice": RELEASED }),
      "abc",
    );
    expect(container.textContent).toBe("");
  });

  // The card is the only thing that would say the setting was written, so
  // a refused write keeps it on screen with the refusal.
  it("keeps the card when the write was refused", async () => {
    vi.mocked(commands.updateSettings).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "the settings file is read-only" },
    });
    const container = await show();
    await press(container, APP_UPDATE_DISMISS_LABEL);
    expect(container.textContent).toContain("the settings file is read-only");
    expect(container.textContent).toContain(APP_UPDATE_TITLE);
  });
});
