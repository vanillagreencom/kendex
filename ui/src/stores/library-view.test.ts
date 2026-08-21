import { beforeEach, describe, expect, it } from "vitest";
import { NO_FILTERS, useLibraryViewStore } from "./library-view";

describe("library view store", () => {
  // Reset to what the store was created with rather than to a restatement of
  // it, so a filter added to the strip is reset here without anyone editing
  // this line — and so the opening state below is the store's own answer.
  beforeEach(() => {
    useLibraryViewStore.setState(useLibraryViewStore.getInitialState(), true);
  });

  it("opens narrowed by nothing, at the top", () => {
    expect(useLibraryViewStore.getInitialState()).toMatchObject({
      ...NO_FILTERS,
      scrollTop: 0,
    });
  });

  it("adopts every picker of a whole narrowing, stale values included", () => {
    useLibraryViewStore.setState({
      kind: "skill",
      harness: "codex",
      tag: "review",
      from: "some marketplace",
    });

    useLibraryViewStore.getState().setFilters({
      kind: "hook",
      harness: "claude",
      tag: "any",
      from: "any",
    });

    const state = useLibraryViewStore.getState();
    expect(state.kind).toBe("hook");
    expect(state.harness).toBe("claude");
    expect(state.tag).toBe("any");
    expect(state.from).toBe("any");
  });

  it("leaves the scroll offset to whoever owns it", () => {
    useLibraryViewStore.setState({ scrollTop: 480 });

    useLibraryViewStore.getState().setFilters(NO_FILTERS);

    expect(useLibraryViewStore.getState().scrollTop).toBe(480);
  });

  it("changes one picker at a time without disturbing the rest", () => {
    useLibraryViewStore.getState().setKind("agent");
    useLibraryViewStore.getState().setTag("deploy");

    const state = useLibraryViewStore.getState();
    expect(state.kind).toBe("agent");
    expect(state.tag).toBe("deploy");
    expect(state.harness).toBe("any");
    expect(state.from).toBe("any");
  });
});
