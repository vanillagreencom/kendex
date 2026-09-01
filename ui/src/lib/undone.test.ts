import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { saying, sayUndone } from "./undone";

vi.mock("sonner", () => ({
  toast: { message: vi.fn() },
}));

beforeEach(() => {
  vi.mocked(toast.message).mockClear();
});

describe("saying what a removal ran", () => {
  it("says nothing when nothing was armed", () => {
    sayUndone([]);
    sayUndone(undefined);
    expect(toast.message).not.toHaveBeenCalled();
  });

  // A departing package's uninstaller is a third party writing as much as
  // it likes, and sonner shows three toasts at a time for four seconds
  // each — so an uncapped account is a minutes-long drain over whatever
  // the person does next. The lines that name the package and what ran
  // come first; the tail is the script talking.
  it("shows the first ten lines and counts the rest", () => {
    sayUndone(Array.from({ length: 26 }, (_, n) => `line ${n}`));

    expect(toast.message).toHaveBeenCalledTimes(11);
    expect(toast.message).toHaveBeenNthCalledWith(10, "line 9");
    expect(toast.message).toHaveBeenLastCalledWith("and 16 more lines");
  });

  it("counts one leftover line in the singular", () => {
    sayUndone(Array.from({ length: 11 }, (_, n) => `line ${n}`));
    expect(toast.message).toHaveBeenLastCalledWith("and 1 more line");
  });

  it("says exactly ten lines without a tally after them", () => {
    sayUndone(Array.from({ length: 10 }, (_, n) => `line ${n}`));
    expect(toast.message).toHaveBeenCalledTimes(10);
  });
});

describe("the account a write's answer carries", () => {
  const RAN = "guards: running scripts/arm --uninstall";

  it("reads it off the answer itself", () => {
    saying({ status: "ok", data: { undone: [RAN] } });
    expect(toast.message).toHaveBeenCalledWith(RAN);
  });

  it("reads it off the standing the answer nests", () => {
    saying({ status: "ok", data: { view: { undone: [RAN] } } });
    expect(toast.message).toHaveBeenCalledWith(RAN);
  });

  it("says nothing for a refusal, which accounts for nothing", () => {
    saying({ status: "error", error: "the plan was refused" });
    expect(toast.message).not.toHaveBeenCalled();
  });

  it("says nothing for an answer that carries no account", () => {
    saying({ status: "ok", data: { ignored: true } });
    saying({ status: "ok", data: null });
    saying(undefined);
    expect(toast.message).not.toHaveBeenCalled();
  });

  it("hands the answer straight back", () => {
    const answer = { status: "ok" as const, data: { undone: [RAN] } };
    expect(saying(answer)).toBe(answer);
  });
});
