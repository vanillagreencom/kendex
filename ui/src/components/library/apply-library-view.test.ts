import { beforeEach, describe, expect, it } from "vitest";
import { UNFILTERED } from "@/lib/library-handoff";
import { NO_FILTERS, useLibraryViewStore } from "@/stores/library-view";
import { useNavStore } from "@/stores/nav";
import { applyLibraryView } from "./use-filter-handoff";

describe("applyLibraryView", () => {
  beforeEach(() => {
    useLibraryViewStore.setState({ ...NO_FILTERS, scrollTop: 0 });
    useNavStore.setState({ search: "", libraryScope: "all" });
  });

  it("puts every part of a view where that part is kept", () => {
    applyLibraryView({
      filters: { kind: "hook", harness: "claude", tag: "any", from: "any" },
      search: "deploy",
      scope: { project: "/x" },
    });

    const view = useLibraryViewStore.getState();
    expect(view.kind).toBe("hook");
    expect(view.harness).toBe("claude");
    expect(useNavStore.getState().search).toBe("deploy");
    expect(useNavStore.getState().libraryScope).toEqual({ project: "/x" });
  });

  it("clears what an earlier view left behind", () => {
    useLibraryViewStore.setState({ kind: "skill", tag: "review" });
    useNavStore.setState({ search: "old", libraryScope: "global" });

    applyLibraryView(UNFILTERED);

    const view = useLibraryViewStore.getState();
    expect(view.kind).toBe("any");
    expect(view.tag).toBe("any");
    expect(useNavStore.getState().search).toBe("");
    expect(useNavStore.getState().libraryScope).toBe("all");
  });
});
