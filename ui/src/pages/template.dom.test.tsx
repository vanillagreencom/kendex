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
import type { Resolution, Template_Serialize } from "@/bindings";
import { commands } from "@/bindings";
import { COPY_PATH_LABEL } from "@/lib/copy";
import {
  FILES_UNREADABLE,
  NO_FILES,
  REMOVE_MEMBER_LABEL,
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
