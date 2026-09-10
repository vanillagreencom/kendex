// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectChanges } from "@/bindings";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  COULD_NOT_CHECK,
  changesToReview,
  REVIEW_CHANGES_LABEL,
} from "@/lib/copy-project-changes";
import { READ_LANDED, readFailed } from "@/lib/read-state";
import { useNavStore } from "@/stores/nav";
import { useProjectChangesStore } from "@/stores/project-changes";
import { mount, settle } from "@/test/dom";
import { ChangesLine } from "./changes-line";

vi.mock("@/bindings", () => ({
  commands: {
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
    libraryProvenance: vi.fn(),
    projectChangesScan: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const ROOT = "/home/method/dev/site";

const pending = (files: string[]): ProjectChanges => ({
  root: ROOT,
  name: "site",
  state: {
    kind: "pending",
    files,
    shared: [],
    others: 0,
    branch: "main",
    operation: null,
  },
});

beforeEach(() => {
  useProjectChangesStore.setState({ rows: [], read: READ_LANDED });
  useNavStore.setState({ page: "projects", changesRoot: null, history: [] });
});

describe("a project's line about what is waiting", () => {
  it("says how much is waiting and opens the review", async () => {
    useProjectChangesStore.setState({ rows: [pending(["a.md", "b.md"])] });
    const host = mount(<ChangesLine root={ROOT} />);
    await settle();
    expect(host.textContent).toContain(changesToReview(2));
    expect(host.textContent).toContain(REVIEW_CHANGES_LABEL);

    await userEvent.click(host.querySelector("button") as HTMLElement);
    await settle();
    const nav = useNavStore.getState();
    expect(nav.page).toBe("projectChanges");
    expect(nav.changesRoot).toBe(ROOT);
  });

  // Zero is not news. A line on every project saying so would be a
  // permanent notice about the ordinary state.
  it("says nothing about a project with nothing waiting", async () => {
    useProjectChangesStore.setState({
      rows: [{ root: ROOT, name: "site", state: { kind: "clean" } }],
    });
    const host = mount(<ChangesLine root={ROOT} />);
    await settle();
    expect(host.textContent).toBe("");
  });

  // A first read still on its way says nothing at all: it will answer on
  // its own, and a notice meanwhile would flash on every start-up.
  it("says nothing while the first read is still on its way", async () => {
    const host = mount(<ChangesLine root={ROOT} />);
    await settle();
    expect(host.textContent).toBe("");
  });

  // A read that failed is not zero changes. It says so and offers the read
  // again rather than drawing a project as clean.
  it("says the check failed rather than showing nothing waiting", async () => {
    useProjectChangesStore.setState({
      rows: [],
      read: readFailed("git is not on the path"),
    });
    const host = mount(<ChangesLine root={ROOT} />);
    await settle();
    expect(host.textContent).toContain(COULD_NOT_CHECK);
    expect(host.textContent).toContain(TRY_AGAIN_LABEL);
  });

  // A project whose own row says the read of IT would not run says the
  // same, even where the read as a whole landed.
  it("says the check failed for a project whose own read refused", async () => {
    useProjectChangesStore.setState({
      rows: [
        {
          root: ROOT,
          name: "site",
          state: { kind: "unreadable", said: ["fatal: bad object HEAD"] },
        },
      ],
      read: READ_LANDED,
    });
    const host = mount(<ChangesLine root={ROOT} />);
    await settle();
    expect(host.textContent).toContain(COULD_NOT_CHECK);
  });
});
