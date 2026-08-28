// @vitest-environment jsdom
// The account row says what the last read settled on and nothing more. What
// these tests hold to is the difference between a stored credential and a
// confirmed one, and between a read that has not landed and one that failed.
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  ACCOUNT_EXPIRED_TITLE,
  ACCOUNT_OFFLINE_LABEL,
  ACCOUNT_OFFLINE_TITLE,
  ACCOUNT_SIGN_IN_AGAIN_LABEL,
  ACCOUNT_SIGN_IN_LABEL,
  ACCOUNT_SIGNED_IN_LABEL,
  ACCOUNT_UNREADABLE_LABEL,
} from "@/lib/copy";
import { type AccountState, useAccountStore } from "@/stores/account";
import { useNavStore } from "@/stores/nav";
import { mount } from "@/test/dom";
import { accountInitial, SidebarAccount } from "./sidebar-account";

vi.mock("@/bindings", () => ({ commands: {} }));

const ADA = { name: "Ada Lovelace", githubLogin: "ada" };

const show = (account: AccountState, readError: string | null = null) => {
  useAccountStore.setState({ account, readError });
  return mount(<SidebarAccount />);
};

/** The row itself, which is the gutter wrapper's only child. */
const rowOf = (host: HTMLElement): HTMLElement => {
  const row = host.firstElementChild?.firstElementChild;
  if (!(row instanceof HTMLElement))
    throw new Error("no account row on screen");
  return row;
};

/** The row's text column, which is the second thing in the row. */
const labelOf = (host: HTMLElement): HTMLElement => {
  const label = rowOf(host).children[1];
  if (!(label instanceof HTMLElement))
    throw new Error("no label in the account row");
  return label;
};

/** The two rows that show a handle, and so have a tooltip of their own. */
const WITH_HANDLE: [string, AccountState][] = [
  ["signed-in", { kind: "signed-in", identity: ADA }],
  ["offline", { kind: "offline", identity: ADA }],
];

/** The states a read can settle on, each named for the message it fails in. */
const SETTLED: [string, AccountState][] = [
  ["signed-in", { kind: "signed-in", identity: ADA }],
  ["signed-out", { kind: "signed-out" }],
  ["expired", { kind: "expired" }],
  ["offline", { kind: "offline", identity: ADA }],
];

beforeEach(() => {
  useAccountStore.setState({ account: { kind: "loading" }, readError: null });
  useNavStore.setState({ page: "home", history: [], future: [] });
});

describe("what the account row draws", () => {
  it("draws nothing while the first read is still out", () => {
    expect(show({ kind: "loading" }).textContent).toBe("");
  });

  it("says a read failed rather than showing a signed-out row", () => {
    const host = show({ kind: "loading" }, "no network");
    expect(host.textContent).toContain(ACCOUNT_UNREADABLE_LABEL);
    expect(host.textContent).not.toContain(ACCOUNT_SIGN_IN_LABEL);
    // Nothing here retries a read: the startup effect does that on focus.
    expect(host.querySelector("button")).toBeNull();
    // The label says a read failed; the tooltip is the only place the
    // reason for it reaches a person.
    expect(rowOf(host).title).toBe("no network");
  });

  it("offers a quiet sign-in when signed out", () => {
    expect(show({ kind: "signed-out" }).textContent).toBe(
      ACCOUNT_SIGN_IN_LABEL,
    );
  });

  it("asks for a fresh sign-in when the credential is expired", () => {
    expect(show({ kind: "expired" }).textContent).toBe(
      ACCOUNT_SIGN_IN_AGAIN_LABEL,
    );
  });

  it("shows the handle and its initial when signed in", () => {
    const row = show({ kind: "signed-in", identity: ADA });
    expect(row.textContent).toContain("ada");
    expect(row.textContent).toContain("A");
    expect(row.textContent).not.toContain(ACCOUNT_OFFLINE_LABEL);
  });

  // A credential in the keychain is not a person: the row may say it is
  // signed in, but it must not put a name or a letter to an account the
  // server has not named.
  it("names nobody when the credential has no identity yet", () => {
    const row = show({ kind: "signed-in", identity: null });
    expect(row.textContent).toBe(ACCOUNT_SIGNED_IN_LABEL);
  });

  it("reads as offline when the credential could not be confirmed", () => {
    const row = show({ kind: "offline", identity: ADA });
    expect(row.textContent).toContain("ada");
    expect(row.textContent).toContain(ACCOUNT_OFFLINE_LABEL);
  });
});

describe("where the row leads", () => {
  it.each(SETTLED)(
    "opens the settings page from the %s row",
    async (_state, account) => {
      const host = show(account);
      const button = host.querySelector("button");
      if (!button) throw new Error("the row is not clickable");
      await userEvent.click(button);
      expect(useNavStore.getState().page).toBe("settings");
    },
  );
});

// A read that fails after one that landed changes no state: it leaves the
// account exactly as the last good answer left it and records only why it
// could not be repeated. Without the cause on the row, the same failure
// would be loud before the first answer and silent ever after.
describe("a read that failed after one that landed", () => {
  it.each(SETTLED)("marks the %s row with the cause", (_state, account) => {
    const clean = rowOf(show(account)).title;
    const failed = rowOf(show(account, "keychain locked")).title;
    expect(failed).toContain("keychain locked");
    expect(failed).not.toBe(clean);
  });

  // A rejected credential and a read that could not be made are different
  // answers. Where the row's own sentence is the only thing explaining what
  // it draws, a later failure joins it rather than taking its place.
  it.each([
    ["expired", { kind: "expired" }, ACCOUNT_EXPIRED_TITLE],
    ["offline", { kind: "offline", identity: ADA }, ACCOUNT_OFFLINE_TITLE],
  ] as [string, AccountState, string][])(
    "keeps the %s row's own explanation beside the cause",
    (_state, account, sentence) => {
      const title = rowOf(show(account, "keychain locked")).title;
      expect(title).toContain(sentence);
      expect(title).toContain("keychain locked");
    },
  );

  // The label covers most of the row, so its own tooltip would answer the
  // hover with the handle and the cause would reach nobody.
  it.each(WITH_HANDLE)(
    "drops the %s row's handle tooltip while a read has failed",
    (_state, account) => {
      expect(labelOf(show(account)).title).toBe(ADA.githubLogin);
      expect(labelOf(show(account, "keychain locked")).title).toBe("");
    },
  );
});

describe("the letter on the avatar", () => {
  it("takes the name's first letter", () => {
    expect(accountInitial(ADA)).toBe("A");
  });

  it("falls back to the handle when there is no name", () => {
    expect(accountInitial({ name: null, githubLogin: "ada" })).toBe("A");
  });

  // A name the server sent as blank is no name at all, so it falls through
  // rather than putting a space on the circle.
  it("falls back to the handle when the name is blank", () => {
    expect(accountInitial({ name: "   ", githubLogin: "grace" })).toBe("G");
  });

  it("has no letter for an account with no identity", () => {
    expect(accountInitial(null)).toBeNull();
  });

  it("keeps a first character that is a surrogate pair whole", () => {
    expect(accountInitial({ name: "𝔄da", githubLogin: "ada" })).toBe("𝔄");
  });
});
