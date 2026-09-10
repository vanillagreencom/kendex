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
});
