import { beforeEach, describe, expect, it } from "vitest";
import { NO_FILTERS, useLibraryViewStore } from "./library-view";

describe("library view store", () => {
  beforeEach(() => {
    useLibraryViewStore.setState({ ...NO_FILTERS, scrollTop: 0 });
  });

  it("opens narrowed by nothing", () => {
    const state = useLibraryViewStore.getState();
    expect(state.kind).toBe("any");
    expect(state.harness).toBe("any");
    expect(state.tag).toBe("any");
    expect(state.from).toBe("any");
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
