import { beforeEach, describe, expect, it } from "vitest";
import { UNFILTERED } from "@/lib/library-handoff";
import { useLibraryViewStore } from "@/stores/library-view";
import { useNavStore } from "@/stores/nav";
import { applyLibraryView } from "./use-filter-handoff";

describe("applyLibraryView", () => {
  // Both halves start from the one definition of an unfiltered view, so a
  // change to what unfiltered means reaches this suite. Only the two fields
  // the view owns are touched: the nav store also holds the page, its history
  // and refs, which this suite has no business resetting.
  beforeEach(() => {
    useLibraryViewStore.setState(useLibraryViewStore.getInitialState(), true);
    useNavStore.setState({
      search: UNFILTERED.search,
      libraryScope: UNFILTERED.scope,
    });
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
    expect(useNavStore.getState().search).toBe(UNFILTERED.search);
    expect(useNavStore.getState().libraryScope).toBe(UNFILTERED.scope);
  });
});
