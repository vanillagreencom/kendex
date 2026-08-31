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
  ACCOUNT_ROW_TITLE,
  ACCOUNT_SIGN_IN_AGAIN_LABEL,
  ACCOUNT_SIGN_IN_LABEL,
  ACCOUNT_SIGNED_IN_LABEL,
  ACCOUNT_UNREADABLE_LABEL,
} from "@/lib/copy-account";
import { type AccountState, useAccountStore } from "@/stores/account";
import { useNavStore } from "@/stores/nav";
import { mount } from "@/test/dom";
import { SidebarAccount } from "./sidebar-account";

/** The name core mints for a sign-in; two answers about one
 *  credential carry the same one. */

vi.mock("@/bindings", () => ({ commands: {} }));

// The provider's account id is an opaque number, not a handle. Every
// fixture spells it that way so a test cannot pass by showing one.
const ADA = { name: "Ada Lovelace", githubLogin: "1234567" };

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

/** What the row puts on screen, without the sentence written for a screen
 *  reader. */
const seen = (host: HTMLElement): string =>
  [...rowOf(host).children]
    .filter((child) => !child.classList.contains("sr-only"))
    .map((child) => child.textContent)
    .join("");

/** The sentence behind the row: the tooltip's words, which the trigger also
 *  carries as its own text so a screen reader reaches them. */
const spoken = (host: HTMLElement): string =>
  rowOf(host).querySelector(".sr-only")?.textContent ?? "";

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
    expect(seen(host)).toContain(ACCOUNT_UNREADABLE_LABEL);
    expect(seen(host)).not.toContain(ACCOUNT_SIGN_IN_LABEL);
    expect(spoken(host)).toBe(ACCOUNT_ROW_TITLE);
  });

  // The reason and the retry live in Settings > Account, so the row that
  // reports the failure is the way to them.
  it("opens the settings page from a failed read", async () => {
    const host = show({ kind: "loading" }, "no network");
    await userEvent.click(rowOf(host));
    expect(useNavStore.getState().page).toBe("settings");
  });

  it("offers a quiet sign-in when signed out", () => {
    expect(seen(show({ kind: "signed-out" }))).toBe(ACCOUNT_SIGN_IN_LABEL);
  });

  it("asks for a fresh sign-in when the credential is expired", () => {
    expect(seen(show({ kind: "expired" }))).toBe(ACCOUNT_SIGN_IN_AGAIN_LABEL);
  });

  it("shows the name and its initial when signed in", () => {
    const host = show({ kind: "signed-in", identity: ADA });
    expect(seen(host)).toContain(ADA.name);
    expect(seen(host)).toContain("A");
    expect(seen(host)).not.toContain(ACCOUNT_OFFLINE_LABEL);
  });

  // The field is the provider's immutable account id, not a handle. It is
  // nobody's name and belongs nowhere a person can read it.
  it.each(SETTLED)(
    "never shows the %s row's provider id",
    (_state, account) => {
      expect(show(account).textContent).not.toContain(ADA.githubLogin);
    },
  );

  // A credential in the keychain is not a person: the row may say it is
  // signed in, but it must not put a name or a letter to an account the
  // server has not named.
  it("names nobody when the credential has no identity yet", () => {
    expect(seen(show({ kind: "signed-in", identity: null }))).toBe(
      ACCOUNT_SIGNED_IN_LABEL,
    );
  });

  // The server answers with a String, so a blank one is a name it does not
  // have rather than a field it did not send.
  it("names nobody when the server sent a blank name", () => {
    const blank = { name: "  ", githubLogin: "1234567" };
    expect(seen(show({ kind: "signed-in", identity: blank }))).toBe(
      ACCOUNT_SIGNED_IN_LABEL,
    );
  });

  it("reads as offline when the credential could not be confirmed", () => {
    const host = show({ kind: "offline", identity: ADA });
    expect(seen(host)).toContain(ADA.name);
    expect(seen(host)).toContain(ACCOUNT_OFFLINE_LABEL);
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

// The reason a row reads the way it does must reach a keyboard and a screen
// reader, not a pointer alone: the trigger takes focus and carries the words
// as its own text, and no row leaves them to a native tooltip.
describe("how the sentence behind a row reaches a person", () => {
  it.each(SETTLED)("focuses the %s row", (_state, account) => {
    const row = rowOf(show(account));
    row.focus();
    expect(document.activeElement).toBe(row);
  });

  it("focuses the row a failed read leaves", () => {
    const row = rowOf(show({ kind: "loading" }, "no network"));
    row.focus();
    expect(document.activeElement).toBe(row);
  });

  it("keeps the failed-read row a button, since it acts too", () => {
    expect(rowOf(show({ kind: "loading" }, "no network")).tagName).toBe(
      "BUTTON",
    );
  });

  it.each(SETTLED)(
    "keeps the %s row a button, since it acts",
    (_s, account) => {
      expect(rowOf(show(account)).tagName).toBe("BUTTON");
    },
  );

  it.each(SETTLED)("leaves no native tooltip on the %s row", (_s, account) => {
    const host = show(account, "keychain locked");
    expect(host.querySelectorAll("[title]")).toHaveLength(0);
  });
});

// Each row's sentence is its own: what the state means for the two that
// mean something the row cannot show, and where the click goes for the rest.
describe("the sentence behind each row", () => {
  it.each([
    ["signed-in", { kind: "signed-in", identity: ADA }, ACCOUNT_ROW_TITLE],
    ["signed-out", { kind: "signed-out" }, ACCOUNT_ROW_TITLE],
    ["expired", { kind: "expired" }, ACCOUNT_EXPIRED_TITLE],
    ["offline", { kind: "offline", identity: ADA }, ACCOUNT_OFFLINE_TITLE],
  ] as [string, AccountState, string][])(
    "says what the %s row means",
    (_state, account, sentence) => {
      expect(spoken(show(account))).toBe(sentence);
    },
  );
});

// A read that fails after one that landed changes no state: it leaves the
// account exactly as the last good answer left it. The row therefore reads
// the same either way, and the cause it does not carry is on the page every
// row opens.
describe("a read that failed after one that landed", () => {
  it.each(SETTLED)("leaves the %s row as it was", (_state, account) => {
    const clean = show(account);
    expect(spoken(show(account, "keychain locked"))).toBe(spoken(clean));
    expect(seen(show(account, "keychain locked"))).toBe(seen(clean));
  });

  it.each(SETTLED)(
    "keeps the cause off the %s row, on either surface",
    (_state, account) => {
      const host = show(account, "keychain locked");
      expect(host.textContent).not.toContain("keychain locked");
    },
  );
});
