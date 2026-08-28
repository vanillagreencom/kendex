// @vitest-environment jsdom
// The account row says what the last read settled on and nothing more. What
// these tests hold to is the difference between a stored credential and a
// confirmed one, and between a read that has not landed and one that failed.
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  ACCOUNT_OFFLINE_LABEL,
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

beforeEach(() => {
  useAccountStore.setState({ account: { kind: "loading" }, readError: null });
  useNavStore.setState({ page: "home", history: [], future: [] });
});

describe("what the account row draws", () => {
  it("draws nothing while the first read is still out", () => {
    expect(show({ kind: "loading" }).textContent).toBe("");
  });

  it("says a read failed rather than showing a signed-out row", () => {
    const row = show({ kind: "loading" }, "no network");
    expect(row.textContent).toContain(ACCOUNT_UNREADABLE_LABEL);
    expect(row.textContent).not.toContain(ACCOUNT_SIGN_IN_LABEL);
    // The retry for a failed read belongs to Settings, not to this row.
    expect(row.querySelector("button")).toBeNull();
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
  it("opens the settings page from a signed-in row", async () => {
    const row = show({ kind: "signed-in", identity: ADA });
    const button = row.querySelector("button");
    if (!button) throw new Error("the signed-in row is not clickable");
    await userEvent.click(button);
    expect(useNavStore.getState().page).toBe("settings");
  });

  it("opens the settings page from a signed-out row", async () => {
    const row = show({ kind: "signed-out" });
    const button = row.querySelector("button");
    if (!button) throw new Error("the signed-out row is not clickable");
    await userEvent.click(button);
    expect(useNavStore.getState().page).toBe("settings");
  });
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
