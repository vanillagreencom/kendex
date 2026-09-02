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

  // The account interleaves kendex's own notes with each departing
  // package's output, in name order. A cut by position would spend itself
  // on whoever talks first — the party kendex does not control — and the
  // line it ate was the second package's stand-down notice, the only place
  // kendex says an effect was left standing and names the manual remedy.
  it("says a later package's stand-down after a chatty one", () => {
    const account = [
      "aaa-loud: running scripts/out",
      ...Array.from({ length: 9 }, (_, n) => `chatter ${n}`),
      "zzz-quiet: declares no uninstaller — what it changed about this " +
        "repository stays; to undo: undo it by hand",
    ];

    sayUndone(account);

    expect(toast.message).toHaveBeenCalledTimes(account.length);
    expect(toast.message).toHaveBeenLastCalledWith(account.at(-1));
  });

  it("says every line it is handed, however many that is", () => {
    sayUndone(Array.from({ length: 26 }, (_, n) => `line ${n}`));
    expect(toast.message).toHaveBeenCalledTimes(26);
    expect(toast.message).toHaveBeenLastCalledWith("line 25");
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
