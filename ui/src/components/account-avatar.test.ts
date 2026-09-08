import { describe, expect, it } from "vitest";
import { ACCOUNT_SIGNED_IN_LABEL } from "@/lib/copy-account";
import { accountInitial, accountLabel } from "./account-avatar";

// The provider ID is opaque and cannot stand in for a missing name.
const ADA = { name: "Ada Lovelace", githubLogin: "1234567" };

describe("the account avatar", () => {
  it("keeps the first visible character whole, or leaves an unnamed account empty", () => {
    const rows = [
      { name: "name", identity: ADA, initial: "A" },
      {
        name: "combining accent",
        identity: { name: "e\u0301lodie", githubLogin: null },
        initial: "E\u0301",
      },
      {
        name: "precomposed accent",
        identity: { name: "élodie", githubLogin: null },
        initial: "É",
      },
      {
        name: "expanded casing",
        identity: { name: "ßeta", githubLogin: null },
        initial: "S",
      },
      {
        name: "joined emoji",
        identity: { name: "👩‍🚀 crew", githubLogin: null },
        initial: "👩‍🚀",
      },
      {
        name: "blank name",
        identity: { name: "   ", githubLogin: "1234567" },
        initial: null,
      },
      { name: "no identity", identity: null, initial: null },
      {
        name: "surrogate pair",
        identity: { name: "𝔄da", githubLogin: null },
        initial: "𝔄",
      },
    ];
    expect(rows).toHaveLength(8);
    for (const row of rows) {
      expect(accountInitial(row.identity), row.name).toBe(row.initial);
    }
  });

  it("names the account without exposing the provider ID", () => {
    const rows = [
      { name: "named", identity: ADA, label: ADA.name },
      {
        name: "blank",
        identity: { name: "  ", githubLogin: "1234567" },
        label: ACCOUNT_SIGNED_IN_LABEL,
      },
      { name: "absent", identity: null, label: ACCOUNT_SIGNED_IN_LABEL },
    ];
    expect(rows).toHaveLength(3);
    for (const row of rows) {
      expect(accountLabel(row.identity), row.name).toBe(row.label);
    }
  });
});
