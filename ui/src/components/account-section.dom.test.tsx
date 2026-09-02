// @vitest-environment jsdom
// Settings > Account draws the five things a read can leave behind, and it
// draws them apart. What these hold to is that a credential the server has
// not confirmed is not a confirmed sign-in, that a credential the server
// rejected is not a signed-out account, and that a read which never landed
// says so and offers the retry rather than collapsing into either.
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  ACCOUNT_CANCEL_SIGN_IN_LABEL,
  ACCOUNT_CHECK_LABEL,
  ACCOUNT_CHECKING_NOTE,
  ACCOUNT_EXPIRED_TITLE,
  ACCOUNT_OFFLINE_LABEL,
  ACCOUNT_OFFLINE_TITLE,
  ACCOUNT_RETRY_LABEL,
  ACCOUNT_SIGN_IN_AGAIN_LABEL,
  ACCOUNT_SIGN_IN_GITHUB_LABEL,
  ACCOUNT_SIGN_OUT_LABEL,
  ACCOUNT_SIGNED_IN_NOTE,
  ACCOUNT_SIGNED_OUT_NOTE,
  ACCOUNT_SIGNING_IN_NOTE,
  ACCOUNT_UNCHECKED_NOTE,
  ACCOUNT_UNREADABLE_LABEL,
  ACCOUNT_UNREADABLE_NOTE,
} from "@/lib/copy-account";
import { type AccountState, useAccountStore } from "@/stores/account";
import { mount } from "@/test/dom";
import { AccountSection } from "./account-section";

vi.mock("@/bindings", () => ({ commands: {} }));

// The provider's account id is an opaque number, not a handle. Every
// fixture spells it that way so a test cannot pass by showing one.
const ADA = { name: "Ada Lovelace", githubLogin: "1234567" };

/** The store's actions, stood in for so a press is checked where it lands
 *  rather than through the bridge it would reach. */
const acts = () => ({
  signIn: vi.fn(async () => {}),
  signOut: vi.fn(async () => {}),
  cancelSignIn: vi.fn(),
  load: vi.fn(async () => {}),
});

let act: ReturnType<typeof acts>;

interface Read {
  account?: AccountState;
  reading?: boolean;
  readError?: string | null;
  signingIn?: boolean;
  userCode?: string | null;
  error?: string | null;
}

beforeEach(() => {
  act = acts();
  useAccountStore.setState({
    account: { kind: "loading" },
    reading: false,
    readError: null,
    signingIn: false,
    userCode: null,
    error: null,
    ...act,
  });
});

const show = (state: Read = {}): HTMLElement => {
  useAccountStore.setState(state);
  return mount(<AccountSection />);
};

/** The letter in the circle, which is drawn for the eye alone. */
const initial = (host: HTMLElement): string =>
  host.querySelector("[aria-hidden]")?.textContent ?? "";

/** Every button the section offers, by the words on it. */
const offered = (host: HTMLElement): string[] =>
  [...host.querySelectorAll("button")].map((b) => b.textContent ?? "");

const press = async (host: HTMLElement, label: string) => {
  const button = [...host.querySelectorAll("button")].find(
    (b) => b.textContent === label,
  );
  if (!button)
    throw new Error(
      `no "${label}" button — the section offers ${offered(host)}`,
    );
  await userEvent.click(button);
  return button;
};

/** The two states that carry a server identity, and so the only two with a
 *  provider id to leak. */
const IDENTIFIED: AccountState[] = [
  { kind: "signed-in", identity: ADA },
  { kind: "offline", identity: ADA },
];

describe("the state the section draws", () => {
  it("names the account and offers a sign-out when signed in", () => {
    const host = show({
      account: { kind: "signed-in", identity: ADA },
    });
    expect(host.textContent).toContain(ADA.name);
    expect(initial(host)).toBe("A");
    expect(offered(host)).toEqual([ACCOUNT_SIGN_OUT_LABEL]);
    // A confirmed sign-in and an unconfirmed credential are the pair the
    // old `hasCredential` read collapsed, and the name, the letter and the
    // button are the same on both. The sentence and the marker are not.
    expect(host.textContent).toContain(ACCOUNT_SIGNED_IN_NOTE);
    expect(host.textContent).not.toContain(ACCOUNT_OFFLINE_LABEL);
  });

  // The bug this section had: `hasCredential` is true for offline, so an
  // unconfirmed credential drew as a confirmed sign-in.
  it("marks an unconfirmed credential offline, not signed in", () => {
    const host = show({
      account: { kind: "offline", identity: ADA },
    });
    expect(host.textContent).toContain(ADA.name);
    expect(host.textContent).toContain(ACCOUNT_OFFLINE_LABEL);
    expect(host.textContent).toContain(ACCOUNT_OFFLINE_TITLE);
    expect(host.textContent).not.toContain(ACCOUNT_SIGNED_IN_NOTE);
    // The credential is still this machine's to drop, and dropping it is
    // what stops the app asking the server about it.
    expect(offered(host)).toEqual([ACCOUNT_SIGN_OUT_LABEL]);
  });

  // The other half of that bug: `hasCredential` is false for expired, so a
  // rejected credential drew as a plain signed-out account.
  it("says a rejected credential was rejected, not signed out", () => {
    const host = show({ account: { kind: "expired" } });
    expect(host.textContent).toContain(ACCOUNT_EXPIRED_TITLE);
    expect(host.textContent).not.toContain(ACCOUNT_SIGNED_OUT_NOTE);
    expect(offered(host)).toEqual([ACCOUNT_SIGN_IN_AGAIN_LABEL]);
  });

  it("offers the device flow when signed out", () => {
    const host = show({ account: { kind: "signed-out" } });
    expect(host.textContent).toContain(ACCOUNT_SIGNED_OUT_NOTE);
    expect(offered(host)).toEqual([ACCOUNT_SIGN_IN_GITHUB_LABEL]);
  });

  // The field is the provider's immutable account id, not a handle. It is
  // nobody's name and belongs nowhere a person can read it.
  it("never shows the provider id of a credential it draws", () => {
    for (const account of IDENTIFIED) {
      expect(show({ account }).textContent).not.toContain(ADA.githubLogin);
    }
  });
});

// A read still out, a read that failed and a read never made are three
// different things, and none of them is a signed-out account.
describe("before any read has landed", () => {
  it("says a read is on its way and offers nothing to press", () => {
    const host = show({ reading: true });
    expect(host.textContent).toContain(ACCOUNT_CHECKING_NOTE);
    expect(offered(host)).toEqual([]);
  });

  it("asks for the read that was never made", async () => {
    const host = show({});
    expect(host.textContent).toContain(ACCOUNT_UNCHECKED_NOTE);
    await press(host, ACCOUNT_CHECK_LABEL);
    expect(act.load).toHaveBeenCalledTimes(1);
  });

  // The order the unread arm checks in: a retry still out is a read on its
  // way, not the failure it was sent to repeat.
  it("says a read is on its way while the retry it started is out", () => {
    const host = show({ reading: true, readError: "keychain locked" });
    expect(host.textContent).toContain(ACCOUNT_CHECKING_NOTE);
    expect(host.textContent).not.toContain(ACCOUNT_UNREADABLE_NOTE);
  });

  it("reports the failure rather than drawing a signed-out account", () => {
    const host = show({ readError: "keychain locked" });
    expect(host.textContent).toContain(ACCOUNT_UNREADABLE_NOTE);
    expect(host.textContent).not.toContain(ACCOUNT_SIGNED_OUT_NOTE);
    expect(offered(host)).toEqual([ACCOUNT_RETRY_LABEL]);
  });
});

// docs/ARCHITECTURE.md: a failed read shows its error with a retry. This is
// the only retry in the app, and the only place the cause is written out.
describe("the retry a failed read gets", () => {
  it("shows the cause the read gave", () => {
    const host = show({ readError: "keychain locked" });
    expect(host.textContent).toContain(ACCOUNT_UNREADABLE_LABEL);
    expect(host.textContent).toContain("keychain locked");
  });

  it("retries through the store's one read", async () => {
    const host = show({ readError: "keychain locked" });
    await press(host, ACCOUNT_RETRY_LABEL);
    expect(act.load).toHaveBeenCalledTimes(1);
  });

  // A read that failed after one that landed leaves the state alone, so the
  // state keeps its own row and the failure gets a second one.
  it("sits beside a state that did land", () => {
    const host = show({
      account: { kind: "offline", identity: ADA },
      readError: "keychain locked",
    });
    expect(host.textContent).toContain("keychain locked");
    expect(offered(host)).toEqual([
      ACCOUNT_SIGN_OUT_LABEL,
      ACCOUNT_RETRY_LABEL,
    ]);
  });

  // Pressing again while the last press is still out would ask twice for
  // one answer.
  it("cannot be pressed while a read is out", () => {
    const host = show({ readError: "keychain locked", reading: true });
    const retry = [...host.querySelectorAll("button")].find(
      (b) => b.textContent === ACCOUNT_RETRY_LABEL,
    );
    expect(retry?.disabled).toBe(true);
  });

  it("is announced when it appears", () => {
    const host = show({ readError: "keychain locked" });
    expect(host.querySelector("[role='alert']")?.textContent).toContain(
      "keychain locked",
    );
  });
});

describe("signing in and out", () => {
  it("signs out from the row that names the account", async () => {
    const host = show({
      account: { kind: "signed-in", identity: ADA },
    });
    await press(host, ACCOUNT_SIGN_OUT_LABEL);
    expect(act.signOut).toHaveBeenCalledTimes(1);
  });

  it("starts the device flow from a signed-out account", async () => {
    const host = show({ account: { kind: "signed-out" } });
    await press(host, ACCOUNT_SIGN_IN_GITHUB_LABEL);
    expect(act.signIn).toHaveBeenCalledTimes(1);
  });

  it("starts it again from a credential the server rejected", async () => {
    const host = show({ account: { kind: "expired" } });
    await press(host, ACCOUNT_SIGN_IN_AGAIN_LABEL);
    expect(act.signIn).toHaveBeenCalledTimes(1);
  });

  // While the flow is out the section is about the flow: the state it began
  // from is the one it is trying to leave.
  it("shows the code and the way out while the flow is waiting", async () => {
    const host = show({
      account: { kind: "signed-out" },
      signingIn: true,
      userCode: "ABCD-2345",
    });
    expect(host.textContent).toContain("ABCD-2345");
    expect(host.textContent).not.toContain(ACCOUNT_SIGNED_OUT_NOTE);
    expect(offered(host)).toEqual([ACCOUNT_CANCEL_SIGN_IN_LABEL]);
    await press(host, ACCOUNT_CANCEL_SIGN_IN_LABEL);
    expect(act.cancelSignIn).toHaveBeenCalledTimes(1);
  });

  // The code arrives one round trip after the flow starts. Until it does the
  // row says what is being waited on rather than showing an empty code.
  it("says what it is waiting for before the code arrives", () => {
    const host = show({ account: { kind: "signed-out" }, signingIn: true });
    expect(host.textContent).toContain(ACCOUNT_SIGNING_IN_NOTE);
    expect(offered(host)).toEqual([ACCOUNT_CANCEL_SIGN_IN_LABEL]);
  });

  // The two failures have their own fields because they answer different
  // questions. A person who came back from denying an approval must still
  // find that explanation, whatever the read went on to say.
  it("keeps a denied approval's reason beside a failed read's", () => {
    const host = show({
      account: { kind: "signed-out" },
      error: "the approval was denied",
      readError: "keychain locked",
    });
    expect(host.textContent).toContain("the approval was denied");
    expect(host.textContent).toContain("keychain locked");
  });
});
