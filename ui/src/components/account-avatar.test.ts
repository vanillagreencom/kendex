// The letter both account surfaces put in the circle. What these hold to is
// that it is one character a reader would recognise as the first one, and
// that an account the server has not named gets none.
import { describe, expect, it } from "vitest";
import { accountInitial, displayName } from "./account-avatar";

// The provider's account id is an opaque number, not a handle. Every
// fixture spells it that way so a test cannot pass by showing one.
const ADA = { name: "Ada Lovelace", githubLogin: "1234567" };

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

// The field is the provider's immutable account id, not a handle. Nothing
// may fall back to it: it is nobody's name.
describe("what the app calls the account", () => {
  it("is the name the server answered with", () => {
    expect(displayName(ADA)).toBe(ADA.name);
  });

  it("is nothing when the server named nobody", () => {
    expect(displayName({ name: "  ", githubLogin: "1234567" })).toBe("");
    expect(displayName(null)).toBe("");
  });
});
