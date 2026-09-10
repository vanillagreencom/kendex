// The order the template list is held in.
//
// The page and the dialogs start reads of their own and every write starts
// another behind it, so replies arrive in any order. A read that left
// before a write must not put the list it saw back on screen.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Template_Serialize } from "@/bindings";
import { commands } from "@/bindings";
import { useTemplatesStore } from "./templates";

vi.mock("@/bindings", () => ({
  commands: {
    templatesList: vi.fn(),
    templateDelete: vi.fn(),
  },
}));
vi.mock("@/lib/rescan", () => ({ writingRepo: (run: () => unknown) => run() }));

const TEMPLATE: Template_Serialize = {
  name: "Rust service",
  id: "rust-service",
  members: [],
  customizations: {},
};

/** A template the person deletes below. Not among the rows the app has:
 *  the read that would have put it there is the one still in flight. */
const DOOMED: Template_Serialize = {
  name: "Doomed",
  id: "doomed",
  members: [],
  customizations: {},
};

/** What a list read answers with, either way. */
type Listed =
  | { status: "ok"; data: Template_Serialize[] }
  | { status: "error"; error: string };

beforeEach(() => {
  vi.clearAllMocks();
  useTemplatesStore.setState({
    templates: [TEMPLATE],
    everRead: true,
    read: { status: "read" },
    busy: false,
    refused: null,
  });
});

describe("overlapping reads of the list", () => {
  it("drops a read that answers after a later write's own read", async () => {
    let answerTheFirstRead: (answer: {
      status: "ok";
      data: Template_Serialize[];
    }) => void = () => {};
    const stillOut = new Promise<{
      status: "ok";
      data: Template_Serialize[];
    }>((resolve) => {
      answerTheFirstRead = resolve;
    });
    vi.mocked(commands.templatesList)
      // The page's read, still on its way.
      .mockReturnValueOnce(stillOut)
      // Every read after it — the one the delete starts behind itself.
      .mockResolvedValue({ status: "ok", data: [] });
    vi.mocked(commands.templateDelete).mockResolvedValue({
      status: "ok",
      data: null,
    });

    const page = useTemplatesStore.getState().load();
    await useTemplatesStore.getState().remove("Rust service");
    expect(useTemplatesStore.getState().templates).toEqual([]);

    // The older read answers last, with the list as it stood before the
    // delete. It is a view something newer has already replaced.
    answerTheFirstRead({ status: "ok", data: [TEMPLATE] });
    await page;
    expect(useTemplatesStore.getState().templates).toEqual([]);
  });

  // The other order, which is the one a guard measured against the last
  // reply HELD lets through: the read that crossed the write answers while
  // the write's own read is still out, so nothing newer has landed to
  // compare it against. A write supersedes the reads that crossed it the
  // moment it starts its own, whichever reply arrives first.
  it("drops a read a write superseded while the newer read is still out", async () => {
    let answerTheSupersededRead: (answer: Listed) => void = () => {};
    const crossedTheWrite = new Promise<Listed>((resolve) => {
      answerTheSupersededRead = resolve;
    });
    let failTheReload: (answer: Listed) => void = () => {};
    const behindTheDelete = new Promise<Listed>((resolve) => {
      failTheReload = resolve;
    });
    vi.mocked(commands.templatesList)
      // The read a surface started before the delete.
      .mockReturnValueOnce(crossedTheWrite as never)
      // The one the delete starts behind itself.
      .mockReturnValueOnce(behindTheDelete as never);
    vi.mocked(commands.templateDelete).mockResolvedValue({
      status: "ok",
      data: null,
    });

    const superseded = useTemplatesStore.getState().load();
    const removing = useTemplatesStore.getState().remove("Doomed");
    await vi.waitFor(() =>
      expect(commands.templatesList).toHaveBeenCalledTimes(2),
    );

    // It answers with the list as it stood before the delete, naming the
    // template the delete has just taken out.
    answerTheSupersededRead({ status: "ok", data: [TEMPLATE, DOOMED] });
    await superseded;
    expect(useTemplatesStore.getState().templates).toEqual([TEMPLATE]);
    // And it does not head the list either: the read that is going to
    // answer for it is still out.
    expect(useTemplatesStore.getState().read).toEqual({ status: "reading" });

    // The newer read then fails. The rows it keeps are the ones it had, not
    // the ones that superseded reply carried.
    failTheReload({
      status: "error",
      error: "the templates could not be read",
    });
    await removing;
    expect(useTemplatesStore.getState().templates).toEqual([TEMPLATE]);
    expect(useTemplatesStore.getState().read).toEqual({
      status: "failed",
      error: "the templates could not be read",
    });
  });
});
