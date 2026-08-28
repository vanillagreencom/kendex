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
} from "@/lib/copy";
import { type AccountState, useAccountStore } from "@/stores/account";
import { useNavStore } from "@/stores/nav";
import { mount } from "@/test/dom";
import { accountInitial, SidebarAccount } from "./sidebar-account";

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
    expect(spoken(host)).toBe("no network");
  });

  // Nothing here retries a read, and nothing here routes to a page that
  // would claim to know an account state this row could not read.
  it("goes nowhere from a failed read", async () => {
    const host = show({ kind: "loading" }, "no network");
    await userEvent.click(rowOf(host));
    expect(useNavStore.getState().page).toBe("home");
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

  // A button announces something to press. The failed read has nothing to
  // press, so the row that reports it must not claim otherwise while still
  // being the only place its sentence lives.
  it("offers no button to press from a failed read", () => {
    const host = show({ kind: "loading" }, "no network");
    expect(rowOf(host).tagName).not.toBe("BUTTON");
    expect(rowOf(host).getAttribute("role")).not.toBe("button");
    expect(host.querySelector("button")).toBeNull();
    expect(spoken(host)).toBe("no network");
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

// A read that fails after one that landed changes no state: it leaves the
// account exactly as the last good answer left it and records only why it
// could not be repeated. Without the cause on the row, the same failure
// would be loud before the first answer and silent ever after.
describe("a read that failed after one that landed", () => {
  it.each(SETTLED)("marks the %s row with the cause", (_state, account) => {
    const clean = spoken(show(account));
    const failed = spoken(show(account, "keychain locked"));
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
      const words = spoken(show(account, "keychain locked"));
      expect(words).toContain(sentence);
      expect(words).toContain("keychain locked");
    },
  );

  // The other two rows explain nothing beyond the click they offer, so the
  // cause takes that hint's place rather than trailing it.
  it.each([
    ["signed-in", { kind: "signed-in", identity: ADA }],
    ["signed-out", { kind: "signed-out" }],
  ] as [string, AccountState][])(
    "replaces the %s row's affordance hint with the cause",
    (_state, account) => {
      expect(spoken(show(account))).toBe(ACCOUNT_ROW_TITLE);
      expect(spoken(show(account, "keychain locked"))).toBe("keychain locked");
    },
  );
});

describe("the letter on the avatar", () => {
  const named = (name: string) => accountInitial({ name, githubLogin: null });

  it("takes the name's first letter", () => {
    expect(accountInitial(ADA)).toBe("A");
  });

  // The accent is part of the letter a reader sees, whether the server sent
  // one character or a base letter and a combining mark.
  it("keeps a combining mark with the letter it belongs to", () => {
    expect(named("e\u0301lodie")).toBe("E\u0301");
    expect(named("élodie")).toBe("É");
  });

  // Casing can widen what it is given: this one letter uppercases to two,
  // and the circle holds one.
  it("keeps one letter when casing expands it", () => {
    expect(named("ßeta")).toBe("S");
  });

  // Every part of the sequence or none: half an emoji is a different emoji.
  it("keeps a multi-part emoji whole", () => {
    expect(named("👩‍🚀 crew")).toBe("👩‍🚀");
  });

  // A name the server sent as blank is no name at all, and the provider id
  // is not a stand-in for one: the circle stays empty.
  it("has no letter for a blank name", () => {
    expect(accountInitial({ name: "   ", githubLogin: "1234567" })).toBeNull();
  });

  it("has no letter for an account with no identity", () => {
    expect(accountInitial(null)).toBeNull();
  });

  it("keeps a first character that is a surrogate pair whole", () => {
    expect(named("𝔄da")).toBe("𝔄");
  });
});
