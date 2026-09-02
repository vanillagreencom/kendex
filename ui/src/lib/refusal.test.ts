import { describe, expect, it } from "vitest";
import type { WriteRefused } from "@/bindings";
import { refusalKind, refusalWords } from "./refusal";

// A transport failure folds to its message alone (`bindings.test.ts`), which
// is neither arm of `WriteRefused`. Read by `kind` it answers as whichever
// arm the reader tests for last: the editor would offer a reload for a broken
// pipe, and the settings write would report a file that moved. These two are
// what every reader of a shaped refusal asks instead.
describe("a refusal the engine shaped", () => {
  it("answers with its own kind and the words that go with it", () => {
    const failed: WriteRefused = { kind: "failed", message: "disk is full" };
    expect(refusalKind(failed)).toBe("failed");
    expect(refusalWords(failed)).toBe("disk is full");
  });

  it("answers with no words where its kind carries none", () => {
    const stale: WriteRefused = { kind: "stale" };
    expect(refusalKind(stale)).toBe("stale");
    expect(refusalWords(stale)).toBeNull();
  });
});

describe("a transport failure folded into a refusal's place", () => {
  // Cast because no refusal type admits it: the fold has no shape it could
  // invent that fits every command's refusal, so it leaves the message.
  const folded = "the channel is gone" as unknown as WriteRefused;

  it("claims no kind of its own", () => {
    expect(refusalKind(folded)).toBeNull();
  });

  it("answers with the message as the words", () => {
    expect(refusalWords(folded)).toBe("the channel is gone");
  });
});
