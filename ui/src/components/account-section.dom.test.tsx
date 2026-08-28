// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useAccountStore } from "@/stores/account";
import { mount, settle } from "@/test/dom";
import { AccountSection } from "./account-section";

vi.mock("@/bindings", () => ({
  commands: { accountStatus: vi.fn() },
}));

const button = (host: HTMLElement) =>
  host.querySelector("button") as HTMLButtonElement;

const click = async (element: HTMLElement) => {
  await act(async () => {
    element.click();
  });
};

// The row is the only way back from a read that failed at launch: nothing
// re-reads until the window is left and returned to.
describe("the account row before any read has landed", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useAccountStore.setState({
      account: { kind: "loading" },
      error: null,
      readError: null,
      reading: false,
      signingIn: false,
      userCode: null,
    });
  });

  it("says it is checking, and does not offer a sign-in it cannot judge", () => {
    useAccountStore.setState({ reading: true });
    const host = mount(<AccountSection />);
    expect(button(host).textContent).toContain("Checking");
    expect(button(host).disabled).toBe(true);
    expect(host.textContent).not.toContain("Sign in with GitHub");
  });

  it("offers a retry once the read has failed, and takes it", async () => {
    useAccountStore.setState({ readError: "keychain locked" });
    const host = mount(<AccountSection />);
    expect(host.textContent).toContain("keychain locked");
    expect(button(host).textContent).toContain("Try again");
    expect(button(host).disabled).toBe(false);

    vi.mocked(commands.accountStatus).mockResolvedValue({
      status: "ok",
      data: { signedIn: true, endpoint: "https://kendex.ai" },
    } as Awaited<ReturnType<typeof commands.accountStatus>>);
    await click(button(host));
    await settle();
    expect(commands.accountStatus).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("Sign out");
    expect(host.textContent).not.toContain("keychain locked");
  });

  // A sign-in started from the submit dialog and abandoned leaves the
  // account unread with no read running and nothing to explain it. The
  // button here is the only way out, so it must not be the dead one.
  it("offers the read when none is running and none has failed", async () => {
    const host = mount(<AccountSection />);
    expect(button(host).disabled).toBe(false);
    expect(button(host).textContent).toContain("Check now");

    vi.mocked(commands.accountStatus).mockResolvedValue({
      status: "ok",
      data: { signedIn: false, endpoint: "https://kendex.ai" },
    } as Awaited<ReturnType<typeof commands.accountStatus>>);
    await click(button(host));
    await settle();
    expect(commands.accountStatus).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("Sign in with GitHub");
  });
});
