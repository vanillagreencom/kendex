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
    const rows: { name: string; account: string[] | undefined }[] = [
      { name: "empty account", account: [] },
      { name: "undefined account", account: undefined },
    ];

    expect(rows.length, "silent removal table is empty").toBeGreaterThan(0);
    for (const row of rows) {
      vi.mocked(toast.message).mockClear();
      sayUndone(row.account);
      expect(toast.message, row.name).not.toHaveBeenCalled();
    }
  });

  it("says every line, including a later package's stand-down", () => {
    // The final notice is an opaque backend value after another package's
    // output. A positional cut must not hide the manual remedy it carries.
    const chattyAccount = [
      "aaa-loud: running scripts/out",
      ...Array.from({ length: 9 }, (_, n) => `chatter ${n}`),
      "zzz-quiet: declares no uninstaller — what it changed about this " +
        "repository stays; to undo: undo it by hand",
    ];
    const rows: {
      name: string;
      account: string[];
    }[] = [
      {
        name: "later package's stand-down after a chatty one",
        account: chattyAccount,
      },
      {
        name: "every line of a long account",
        account: Array.from({ length: 26 }, (_, n) => `line ${n}`),
      },
    ];

    expect(rows.length, "long removal table is empty").toBeGreaterThan(0);
    for (const row of rows) {
      vi.mocked(toast.message).mockClear();
      sayUndone(row.account);
      expect(vi.mocked(toast.message).mock.calls, row.name).toEqual(
        row.account.map((line) => [line]),
      );
    }
  });
});

describe("the account a write's answer carries", () => {
  const RAN = "guards: running scripts/arm --uninstall";

  it("reads the account from each existing answer shape", () => {
    const rows: { name: string; answer: unknown }[] = [
      {
        name: "on the answer itself",
        answer: { status: "ok", data: { undone: [RAN] } },
      },
      {
        name: "on the standing the answer nests",
        answer: { status: "ok", data: { view: { undone: [RAN] } } },
      },
    ];

    expect(rows.length, "write account shape table is empty").toBeGreaterThan(
      0,
    );
    for (const row of rows) {
      vi.mocked(toast.message).mockClear();
      saying(row.answer);
      expect(toast.message, row.name).toHaveBeenCalledWith(RAN);
    }
  });

  it("says nothing for a refusal or an answer without an account", () => {
    const rows: { name: string; answer: unknown }[] = [
      {
        name: "refusal",
        answer: { status: "error", error: "the plan was refused" },
      },
      {
        name: "answer without an account",
        answer: { status: "ok", data: { ignored: true } },
      },
      { name: "null answer data", answer: { status: "ok", data: null } },
      { name: "undefined answer", answer: undefined },
    ];

    expect(rows.length, "silent write answer table is empty").toBeGreaterThan(
      0,
    );
    for (const row of rows) {
      vi.mocked(toast.message).mockClear();
      saying(row.answer);
      expect(toast.message, row.name).not.toHaveBeenCalled();
    }
  });

  it("hands the answer straight back", () => {
    const answer = { status: "ok" as const, data: { undone: [RAN] } };
    expect(saying(answer)).toBe(answer);
  });
});
