// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useTermsStore } from "@/stores/terms";
import { mount, settle } from "@/test/dom";
import { TermsGate } from "./terms-gate";

vi.mock("@/bindings", () => ({
  LEGAL: {
    version: 1,
    termsUrl: "https://kendex.ai/legal/terms",
    privacyUrl: "https://kendex.ai/legal/privacy",
  },
  commands: {
    termsState: vi.fn(),
    acceptTerms: vi.fn(),
    openUrl: vi.fn(),
    windowMinimize: vi.fn(),
    windowToggleMaximize: vi.fn(),
    windowClose: vi.fn(),
  },
}));

const agree = (host: HTMLElement): HTMLButtonElement | null =>
  [...host.querySelectorAll("button")].find((button) =>
    (button.textContent ?? "").startsWith("I agree"),
  ) ?? null;

beforeEach(() => {
  vi.mocked(commands.termsState).mockReset();
  vi.mocked(commands.acceptTerms).mockReset();
  useTermsStore.setState({ state: null, error: null });
});

describe("the first-run terms screen", () => {
  it("asks when nothing is on record, and records the version on the one button", async () => {
    vi.mocked(commands.termsState).mockResolvedValue({
      status: "ok",
      data: { ask: true, accepted: null },
    });
    vi.mocked(commands.acceptTerms).mockResolvedValue({
      status: "ok",
      data: {
        ask: false,
        accepted: { version: 1, "accepted-at": "2026-09-06T10:00:00Z" },
      },
    });

    const host = mount(<TermsGate />);
    await settle();
    const button = agree(host);
    expect(button).not.toBeNull();

    await act(async () => {
      await userEvent.click(button as HTMLButtonElement);
    });
    expect(commands.acceptTerms).toHaveBeenCalledTimes(1);
    expect(agree(host)).toBeNull();
  });

  // The must-fail half: a screen that drew itself whatever the record said
  // would pass the case above and ask everyone, every launch.
  it("asks nothing once the current version is on record", async () => {
    vi.mocked(commands.termsState).mockResolvedValue({
      status: "ok",
      data: {
        ask: false,
        accepted: { version: 1, "accepted-at": "2026-09-06T10:00:00Z" },
      },
    });

    const host = mount(<TermsGate />);
    await settle();
    expect(agree(host)).toBeNull();
    expect(commands.acceptTerms).not.toHaveBeenCalled();
  });

  // Whether to ask is the backend's answer, not a version comparison made
  // here: an older record reaches this component as the same `ask`.
  it("asks again when the backend says the record is behind", async () => {
    vi.mocked(commands.termsState).mockResolvedValue({
      status: "ok",
      data: {
        ask: true,
        accepted: { version: 1, "accepted-at": "2020-01-01T00:00:00Z" },
      },
    });

    const host = mount(<TermsGate />);
    await settle();
    expect(agree(host)).not.toBeNull();
  });

  it("keeps the screen up and says why when the record could not be written", async () => {
    vi.mocked(commands.termsState).mockResolvedValue({
      status: "ok",
      data: { ask: true, accepted: null },
    });
    vi.mocked(commands.acceptTerms).mockResolvedValue({
      status: "error",
      error: "settings.toml is not writable",
    });

    const host = mount(<TermsGate />);
    await settle();
    await act(async () => {
      await userEvent.click(agree(host) as HTMLButtonElement);
    });
    expect(host.textContent).toContain("settings.toml is not writable");
    expect(agree(host)).not.toBeNull();
  });

  // A read that failed is not evidence that nobody accepted. Asking on it
  // would put the screen in front of a person who answered months ago.
  it("asks nothing when the record could not be read", async () => {
    vi.mocked(commands.termsState).mockResolvedValue({
      status: "error",
      error: "settings.toml is not readable",
    });

    const host = mount(<TermsGate />);
    await settle();
    expect(agree(host)).toBeNull();
  });
});
