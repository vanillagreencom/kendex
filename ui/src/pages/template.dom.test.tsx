// @vitest-environment jsdom
// The template page's two file reads, and what it draws when they fail.
//
// Both are shipped failure paths — templateFiles and templateFile already
// answer as status "error" — and collapsing them turned an unreadable
// store into the no-copies empty state and a read error into the file
// pane's contents. A claim about what a template holds is only made over
// a read that answered.
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { PackageFile, Resolution, Template_Serialize } from "@/bindings";
import { commands } from "@/bindings";
import { COPY_PATH_LABEL } from "@/lib/copy";
import {
  FILES_UNREADABLE,
  NO_FILES,
  REMOVE_MEMBER_LABEL,
  RESOLVE_UNREADABLE,
} from "@/lib/copy-templates";
import { useNavStore } from "@/stores/nav";
import { useTemplatesStore } from "@/stores/templates";
import { mount, settle } from "@/test/dom";
import { TemplatePage } from "./template";

vi.mock("@/bindings", () => ({
  commands: {
    templatesList: vi.fn(),
    templateResolve: vi.fn(),
    templateFiles: vi.fn(),
    templateFile: vi.fn(),
    templateRemoveMembers: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const TEMPLATE: Template_Serialize = {
  name: "Rust service",
  id: "rust-service",
  members: [],
  customizations: {},
};

const RESOLVED: Resolution = { groups: [], copies: [], missing: [] };

beforeEach(() => {
  vi.clearAllMocks();
  useTemplatesStore.setState({
    templates: [TEMPLATE],
    everRead: true,
    read: { status: "read" },
    busy: false,
    refused: null,
  });
  useNavStore.setState({ page: "template", templateName: "Rust service" });
  vi.mocked(commands.templatesList).mockResolvedValue({
    status: "ok",
    data: [TEMPLATE],
  });
  vi.mocked(commands.templateResolve).mockResolvedValue({
    status: "ok",
    data: RESOLVED,
  });
});

describe("the files a template owns", () => {
  it("says the read failed instead of claiming there are no copies", async () => {
    vi.mocked(commands.templateFiles).mockResolvedValue({
      status: "error",
      error: "the template's store could not be read",
    });
    const host = mount(<TemplatePage />);
    await settle();

    expect(host.textContent).toContain(FILES_UNREADABLE);
    expect(host.textContent).not.toContain(NO_FILES);
  });

  it("claims there are no copies only over a read that answered", async () => {
    vi.mocked(commands.templateFiles).mockResolvedValue({
      status: "ok",
      data: [],
    });
    const host = mount(<TemplatePage />);
    await settle();

    expect(host.textContent).toContain(NO_FILES);
    expect(host.textContent).not.toContain(FILES_UNREADABLE);
  });

  it("never renders a failed file read as the file's contents", async () => {
    vi.mocked(commands.templateFiles).mockResolvedValue({
      status: "ok",
      data: [
        { path: "skills/house-style/SKILL.md", size: 12, isReadme: false },
      ],
    });
    vi.mocked(commands.templateFile).mockResolvedValue({
      status: "error",
      error: "that file is not text",
    });
    const host = mount(<TemplatePage />);
    await settle();

    const file = [...host.querySelectorAll<HTMLElement>("button")].find((one) =>
      one.textContent?.includes("SKILL.md"),
    );
    if (!file) throw new Error("no file row in the tree");
    await act(async () => file.click());
    await settle();

    // The reason is on screen as a failure, and no file pane was drawn
    // to render it into — the pane's own Copy path control is the tell.
    expect(host.textContent).toContain("that file is not text");
    const pane = [...host.querySelectorAll("button")].some(
      (one) => one.getAttribute("aria-label") === COPY_PATH_LABEL,
    );
    expect(pane).toBe(false);
  });
});

describe("a member taken out of the template", () => {
  /** The one file the copied member owns, and one another member keeps —
   *  so the tree is still drawn after the removal and the pane's fate is
   *  the selection's own, not the empty state's. */
  const SKILL = {
    path: "skills/house-style/SKILL.md",
    size: 12,
    isReadme: false,
  };
  const KEPT = { path: "commands/note.md", size: 8, isReadme: false };

  /** A resolution holding that member as a copy of the template's own. */
  const withCopy: Resolution = {
    groups: [],
    copies: [
      {
        kind: "skill",
        name: "house-style",
        enabled: true,
        copy: "skills/house-style",
        from: null,
      },
    ],
    missing: [],
  };

  /** The one Remove control on screen. */
  const removeButton = (host: HTMLElement) =>
    [...host.querySelectorAll<HTMLElement>("button")].find((one) =>
      one.textContent?.includes(REMOVE_MEMBER_LABEL),
    );

  it("empties the pane that was showing the file it owned", async () => {
    vi.mocked(commands.templateResolve)
      .mockResolvedValueOnce({ status: "ok", data: withCopy })
      .mockResolvedValue({ status: "ok", data: RESOLVED });
    vi.mocked(commands.templateFiles)
      .mockResolvedValueOnce({ status: "ok", data: [SKILL, KEPT] })
      .mockResolvedValue({ status: "ok", data: [KEPT] });
    vi.mocked(commands.templateFile).mockResolvedValue({
      status: "ok",
      data: "my own bytes",
    });
    vi.mocked(commands.templateRemoveMembers).mockResolvedValue({
      status: "ok",
      data: TEMPLATE,
    });
    const host = mount(<TemplatePage />);
    await settle();

    const file = [...host.querySelectorAll<HTMLElement>("button")].find((one) =>
      one.textContent?.includes("SKILL.md"),
    );
    if (!file) throw new Error("no file row in the tree");
    await act(async () => file.click());
    await settle();
    // The pane is open over that file — its Copy path control is the tell.
    const pane = () =>
      [...host.querySelectorAll("button")].some(
        (one) => one.getAttribute("aria-label") === COPY_PATH_LABEL,
      );
    expect(pane()).toBe(true);

    const remove = removeButton(host);
    if (!remove) throw new Error("no Remove control for the copied member");
    await act(async () => remove.click());
    await settle();

    // The template no longer holds that file, so nothing draws it.
    expect(pane()).toBe(false);
    expect(host.textContent).not.toContain("my own bytes");
  });

  it("drops a refusal another write left standing, and keeps its own", async () => {
    // What a failed add, rename or delete elsewhere leaves on the store:
    // one shared field, cleared only when the next write starts.
    useTemplatesStore.setState({
      refused: "Rust service could not be renamed",
    });
    vi.mocked(commands.templateResolve).mockResolvedValue({
      status: "ok",
      data: withCopy,
    });
    vi.mocked(commands.templateFiles).mockResolvedValue({
      status: "ok",
      data: [SKILL, KEPT],
    });
    vi.mocked(commands.templateRemoveMembers).mockResolvedValue({
      status: "error",
      error: "the member could not be removed",
    });
    const host = mount(<TemplatePage />);
    await settle();

    // Arriving at the page is not the failure's subject, so it is gone.
    expect(host.textContent).not.toContain("Rust service could not be renamed");
    expect(useTemplatesStore.getState().refused).toBe(null);

    // And a refusal this page's own action raises afterwards is shown: the
    // clearing is on the way in, not on every render.
    const remove = removeButton(host);
    if (!remove) throw new Error("no Remove control for the copied member");
    await act(async () => remove.click());
    await settle();

    expect(host.textContent).toContain("the member could not be removed");
  });

  it("names the member by the kind it was saved as", async () => {
    const plugged: Resolution = {
      groups: [
        {
          repo: "owner/repo",
          source: null,
          rev: null,
          version: null,
          lastKnown: false,
          items: [],
          bundles: [{ name: "review", enabled: true, kind: "plugin" }],
        },
      ],
      copies: [],
      missing: [],
    };
    vi.mocked(commands.templateResolve).mockResolvedValue({
      status: "ok",
      data: plugged,
    });
    vi.mocked(commands.templateFiles).mockResolvedValue({
      status: "ok",
      data: [],
    });
    vi.mocked(commands.templateRemoveMembers).mockResolvedValue({
      status: "ok",
      data: TEMPLATE,
    });
    const host = mount(<TemplatePage />);
    await settle();

    const remove = removeButton(host);
    if (!remove) throw new Error("no Remove control for the plugin member");
    await act(async () => remove.click());
    await settle();

    // A reference calling the plugin a bundle names no member the template
    // holds: the row would remove nothing and say nothing.
    expect(commands.templateRemoveMembers).toHaveBeenCalledWith(
      "Rust service",
      [
        {
          kind: "plugin",
          name: "review",
          which: { of: "marketplace", repo: "owner/repo" },
        },
      ],
    );
  });
});

// Three things start a read of this page, so the replies can arrive in any
// order. An answer older than the newest run is a view something newer has
// already replaced, and holding it put a member the person had just
// removed back on screen.
describe("reads of the page that overlap", () => {
  const SKILL = {
    path: "skills/house-style/SKILL.md",
    size: 12,
    isReadme: false,
  };
  const withCopy: Resolution = {
    groups: [],
    copies: [
      {
        kind: "skill",
        name: "house-style",
        enabled: true,
        copy: "skills/house-style",
        from: null,
      },
    ],
    missing: [],
  };
  const withoutCopy: Resolution = { groups: [], copies: [], missing: [] };

  it("drops an answer older than the newest read", async () => {
    // The read the page starts on mount answers with the member, but its
    // file list is still out when the removal below starts a second read.
    let answerTheFirstFiles: (answer: {
      status: "ok";
      data: PackageFile[];
    }) => void = () => {};
    const stillOut = new Promise<{ status: "ok"; data: PackageFile[] }>(
      (resolve) => {
        answerTheFirstFiles = resolve;
      },
    );
    vi.mocked(commands.templateResolve)
      .mockResolvedValueOnce({ status: "ok", data: withCopy })
      .mockResolvedValue({ status: "ok", data: withoutCopy });
    vi.mocked(commands.templateFiles)
      .mockReturnValueOnce(stillOut)
      .mockResolvedValue({ status: "ok", data: [] });
    vi.mocked(commands.templateRemoveMembers).mockResolvedValue({
      status: "ok",
      data: TEMPLATE,
    });

    const host = mount(<TemplatePage />);
    await settle();
    expect(host.textContent).toContain("house-style");

    // Removing the member starts the second read, which answers first.
    const remove = [...host.querySelectorAll<HTMLElement>("button")].find(
      (one) => one.textContent?.includes(REMOVE_MEMBER_LABEL),
    );
    if (!remove) throw new Error("no Remove control for the copied member");
    await act(async () => remove.click());
    await settle();
    expect(host.textContent).not.toContain("house-style");

    // The first read's file list answers last, still holding the file the
    // removed member owned.
    await act(async () => {
      answerTheFirstFiles({ status: "ok", data: [SKILL] });
    });
    await settle();

    expect(host.textContent).not.toContain("SKILL.md");
  });

  it("never draws one file's bytes under another file's name", async () => {
    const OTHER = { path: "commands/note.md", size: 8, isReadme: false };
    vi.mocked(commands.templateResolve).mockResolvedValue({
      status: "ok",
      data: withoutCopy,
    });
    vi.mocked(commands.templateFiles).mockResolvedValue({
      status: "ok",
      data: [SKILL, OTHER],
    });
    vi.mocked(commands.templateFile).mockResolvedValue({
      status: "ok",
      data: "the first file's bytes",
    });
    const host = mount(<TemplatePage />);
    await settle();

    const row = (text: string) =>
      [...host.querySelectorAll<HTMLElement>("button")].find((one) =>
        one.textContent?.includes(text),
      );
    const first = row("SKILL.md");
    if (!first) throw new Error("no first file row");
    await act(async () => first.click());
    await settle();
    expect(host.textContent).toContain("the first file's bytes");

    // The second file's read is held, which is the window this is about:
    // the pane already carries its path.
    let answerTheSecondRead: (answer: { status: "ok"; data: string }) => void =
      () => {};
    vi.mocked(commands.templateFile).mockReturnValueOnce(
      new Promise((resolve) => {
        answerTheSecondRead = resolve;
      }),
    );
    const second = row("note.md");
    if (!second) throw new Error("no second file row");
    await act(async () => second.click());
    await settle();

    // The intermediate state is the assertion: the first file's bytes are
    // gone before the second file's arrive, so nothing is ever drawn — or
    // copied — under a name that is not its own.
    expect(host.textContent).not.toContain("the first file's bytes");

    await act(async () => {
      answerTheSecondRead({ status: "ok", data: "the second file's bytes" });
    });
    await settle();
    expect(host.textContent).toContain("the second file's bytes");
  });
});

// The two reads behind this page are independent, so a resolution that
// would not read says nothing about whether the store lists. Returning on
// that branch left the file half as a previous read had it and still
// marked successful — after a removal that landed, files the template no
// longer owns went on being presented as current.
describe("a resolution that fails after a removal landed", () => {
  it("does not go on showing the removed member's files as current", async () => {
    const SKILL = {
      path: "skills/house-style/SKILL.md",
      size: 12,
      isReadme: false,
    };
    const withCopy: Resolution = {
      groups: [],
      copies: [
        {
          kind: "skill",
          name: "house-style",
          enabled: true,
          copy: "skills/house-style",
          from: null,
        },
      ],
      missing: [],
    };
    vi.mocked(commands.templateResolve)
      .mockResolvedValueOnce({ status: "ok", data: withCopy })
      // The reread the removal starts: this one will not read.
      .mockResolvedValue({
        status: "error",
        error: "the template could not be read",
      });
    vi.mocked(commands.templateFiles)
      .mockResolvedValueOnce({ status: "ok", data: [SKILL] })
      // The store still lists, and what it lists no longer holds the file
      // the removed member owned.
      .mockResolvedValue({ status: "ok", data: [] });
    vi.mocked(commands.templateRemoveMembers).mockResolvedValue({
      status: "ok",
      data: TEMPLATE,
    });

    const host = mount(<TemplatePage />);
    await settle();
    expect(host.textContent).toContain("SKILL.md");

    const remove = [...host.querySelectorAll<HTMLElement>("button")].find(
      (one) => one.textContent?.includes(REMOVE_MEMBER_LABEL),
    );
    if (!remove) throw new Error("no Remove control for the copied member");
    await act(async () => remove.click());
    await settle();

    // The resolution half says it could not be read; the file half says
    // what its own read found, which no longer holds that file.
    expect(host.textContent).toContain(RESOLVE_UNREADABLE);
    expect(host.textContent).not.toContain("SKILL.md");
  });
});
